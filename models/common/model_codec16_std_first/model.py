"""首个残差块使用两层标准3×3，其余四块保留DW/PW，15处IN保持不变。"""
from pathlib import Path
import copy
import torch
from torch import nn
from torch.nn import functional as F
from model_codec16.model import ConvAct
from model_codec16.quantization import Quantizer
from model_codec16_in.model import Codec16IN, INConvAct

ARCHITECTURE = 'stem8_enc16_32_stdres1_sep4_stddec16_8_3_in15_v1'
WEIGHT_ARCHITECTURE = 'stem8_enc16_32_stdres1_sep4_stddec16_8_3_v1'
IN_SITES = (
    'stem', 'enc1', 'enc2', 'body.0.conv1', 'body.0.conv2',
    *[f'body.{i}.{part}' for i in range(1, 5) for part in ['dw', 'pw']],
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

class Codec16StandardFirstIN(Codec16IN):
    """训练入口；固定256×144 RGB，编码器后首先使用标准残差块。"""
    def __init__(self):
        super().__init__()
        self.body[0] = StandardResidual32IN()
        self.set_quantization(False)

    def layer_contract(self):
        layers = []
        previous = self.input_quant
        for name in ['stem', 'enc1', 'enc2']:
            block = getattr(self, name)
            layers.append((name + '.conv', block.conv, previous, block.quant))
            previous = block.quant
        for index, block in enumerate(self.body):
            parts = ['conv1', 'conv2'] if index == 0 else ['dw', 'pw']
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

def from_legacy_model(legacy):
    """将旧DW/PW显式展开为对角核/中心核，作为数学等价的微调起点。"""
    result = Codec16StandardFirstIN()
    state = {}
    for name, value in legacy.state_dict().items():
        target = name.replace('body.0.dw.', 'body.0.conv1.').replace('body.0.pw.', 'body.0.conv2.')
        if name == 'body.0.dw.conv.weight':
            expanded = value.new_zeros(32, 32, 3, 3)
            for channel in range(32):
                expanded[channel, channel] = value[channel, 0]
            value = expanded
        elif name == 'body.0.pw.conv.weight':
            expanded = value.new_zeros(32, 32, 3, 3)
            expanded[:, :, 1, 1] = value[:, :, 0, 0]
            value = expanded
        state[target] = value.clone()
    result.load_state_dict(state, strict=True)
    result.set_quantization(legacy.quant_enabled)
    return result

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
        raise ValueError('需要首块双标准3×3的IN15权重；旧模型只能显式展开初始化。')
    model = Codec16StandardFirstIN()
    model.load_state_dict(payload['state_dict'], strict=True)
    model.set_quantization(payload.get('qat', False))
    return model, payload
