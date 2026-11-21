"""IN after all 15 non-output convolutions, matching adaptive-IN RTL sites."""
from pathlib import Path
import copy
import torch
from torch import nn
from torch.nn import functional as F
from model_codec16.model import Codec16StyleLite

ARCHITECTURE='stem8_enc16_32_sep5_stddec16_8_3_in15_v1'
IN_SITES=('stem','enc1','enc2',*[f'body.{i}.{k}' for i in range(5) for k in ['dw','pw']],'decode_pw','decode1')

class AffineInstanceNorm(nn.InstanceNorm2d):
    """Standard per-image IN, affine=True, no running statistics or batch mixing."""
    def __init__(self,c,eps=1e-5):
        super().__init__(c,eps=eps,affine=True,track_running_stats=False)
    @property
    def gamma(self):return self.weight
    @property
    def beta(self):return self.bias

def canonicalize_gamma(model):
    """Absorb negative gamma into its preceding conv, preserving exact FP32 IN.

    IN(-z)=-IN(z), including epsilon and convolution bias. This permits the
    existing positive INT31 hardware multiplier without restricting training.
    """
    result=copy.deepcopy(model)
    with torch.no_grad():
        for name in IN_SITES:
            module=result.get_submodule(name);sign=torch.where(module.norm.gamma<0,-1.,1.)
            module.conv.weight.mul_(sign[:,None,None,None]);module.conv.bias.mul_(sign);module.norm.weight.abs_()
    return result

class INConvAct(nn.Module):
    def __init__(self,old):
        super().__init__();self.conv=old.conv;self.norm=AffineInstanceNorm(old.conv.out_channels);self.act=old.act;self.quant=old.quant
    def forward(self,x):return self.quant(self.act(self.norm(self.conv(x))))

class Codec16IN(Codec16StyleLite):
    has_adaptive_in=True
    def __init__(self):
        super().__init__()
        for name in ['stem','enc1','enc2','decode_pw','decode1']:setattr(self,name,INConvAct(getattr(self,name)))
        for block in self.body:
            block.dw=INConvAct(block.dw);block.pw=INConvAct(block.pw)
    def forward(self,x):
        if x.shape[-2:]!=(144,256):raise ValueError('This hardware interface requires [N,3,144,256] RGB.')
        return super().forward(x)
    def calibrate(self,images):
        raise RuntimeError('Use a new IN-aware calibration/export flow. Legacy fixed coefficients do not implement dynamic IN.')

def save_checkpoint(path,model,*,trained_for_in=False):
    torch.save({'architecture':ARCHITECTURE,'trained_for_in':bool(trained_for_in),'qat':model.quant_enabled,'input_hw':[144,256],'in_sites':list(IN_SITES),'state_dict':model.state_dict()},Path(path))
def load_checkpoint(path):
    p=torch.load(path,map_location='cpu',weights_only=True)
    if p.get('architecture')!=ARCHITECTURE:raise ValueError('Legacy no-IN weights are not an IN checkpoint.')
    m=Codec16IN();m.load_state_dict(p['state_dict'],strict=True);m.set_quantization(p.get('qat',False));return m,p
