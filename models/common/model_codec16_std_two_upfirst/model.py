"""双标准残差，解码先上采样再卷积，保留15处IN。"""
from pathlib import Path
import copy
import torch
from torch import nn
from torch.nn import functional as F
from model_codec16.model import ConvAct
from model_codec16.quantization import Quantizer
from model_codec16_in.model import Codec16IN, INConvAct

ARCHITECTURE = 'stem8_enc16_32_stdres2_sep3_upfirst32_16_8_3_in15_v1'
WEIGHT_ARCHITECTURE = 'stem8_enc16_32_stdres2_sep3_upfirst32_16_8_3_v1'
IN_SITES = (
    'stem', 'enc1', 'enc2', 'body.0.conv1', 'body.0.conv2',
    'body.1.conv1', 'body.1.conv2', *[f'body.{i}.{part}' for i in range(2, 5) for part in ['dw', 'pw']],
    'decode_pw', 'decode1',
)

class StandardResidual32IN(nn.Module):
    """两层标准3×3分别进行IN，第二层保留有符号输出，再进行残差相加。"""
    def __init__(self):
        super().__init__()
        self.conv1 = INConvAct(ConvAct(32, 32, k=3))
        self.conv2 = INConvAct(ConvAct(32, 32, k=3, activate=False))
        self.add_quant = Quantizer(signed=True)
        self.out_quant = Quantizer()

    def forward(self, value):
        shortcut = self.add_quant(value)
        branch = self.add_quant(self.conv2(self.conv1(value)))
        return self.out_quant(F.relu6(shortcut + branch))

class Codec16TwoStandardUpFirstIN(Codec16IN):
    """训练入口：256×144 RGB，前两个标准残差块，高分辨率解码。"""
    def __init__(self):
        super().__init__()
        self.body[0] = StandardResidual32IN()
        self.body[1] = StandardResidual32IN()
        self.decode_pw = INConvAct(ConvAct(32, 16, k=3))
        self.set_quantization(False)

    def forward(self, x):
        if x.shape[-2:] != (144, 256):
            raise ValueError('需要256×144 RGB输入')
        if self.quant_enabled:
            self.connect_scales()
        x = self.enc2(self.enc1(self.stem(self.input_quant(x))))
        for block in self.body:
            x = block(x)
        x = self.decode_pw(F.interpolate(x, scale_factor=2, mode='nearest'))
        x = self.decode1(F.interpolate(x, scale_factor=2, mode='nearest'))
        return self.output_quant(self.out(x).clamp(0, 1))

    def layer_contract(self):
        layers = []
        previous = self.input_quant
        for name in ['stem', 'enc1', 'enc2']:
            block = getattr(self, name)
            layers.append((name + '.conv', block.conv, previous, block.quant))
            previous = block.quant
        for index, block in enumerate(self.body):
            parts = ['conv1', 'conv2'] if index < 2 else ['dw', 'pw']
            for part in parts:
                node = getattr(block, part)
                layers.append((f'body.{index}.{part}.conv', node.conv, previous, node.quant))
                previous = node.quant
            previous = block.out_quant
        for name in ['decode_pw', 'decode1']:
            block = getattr(self, name)
            layers.append((name + '.conv', block.conv, previous, block.quant))
            previous = block.quant
        layers.append(('out', self.out, previous, self.output_quant))
        return layers

def canonicalize_gamma(model):
    """将IN的负gamma吸收到前级卷积，保持正INT31硬件乘数约定。"""
    result = copy.deepcopy(model)
    with torch.no_grad():
        for name in IN_SITES:
            node = result.get_submodule(name)
            sign = torch.where(node.norm.gamma < 0, -1., 1.)
            node.conv.weight.mul_(sign[:, None, None, None])
            node.conv.bias.mul_(sign)
            node.norm.weight.abs_()
    return result

def save_checkpoint(path, model, *, trained_for_in=False):
    torch.save({
        'architecture': ARCHITECTURE,
        'trained_for_in': bool(trained_for_in),
        'qat': model.quant_enabled,
        'input_hw': [144, 256],
        'in_sites': list(IN_SITES),
        'state_dict': model.state_dict(),
    }, Path(path))

def load_checkpoint(path):
    payload = torch.load(path, map_location='cpu', weights_only=True)
    if payload.get('architecture') != ARCHITECTURE:
        raise ValueError('需要双标准残差、解码上采样提前的IN15权重；旧模型不能直接部署。')
    model = Codec16TwoStandardUpFirstIN()
    model.load_state_dict(payload['state_dict'], strict=True)
    model.set_quantization(payload.get('qat', False))
    return model, payload
