"""Training/QAT interface for Codec16: 256x144, C8 stem and C16/C32 encoders, five C32 residuals, two ordinary upsampling convolutions16->8->3.

No trained Codec16 weights are distributed. A legacy checkpoint is not compatible.
All 3x3 convolutions use replicate padding; the decoder projects 32->16 before nearest-neighbor x2, ordinary16->8, followed by nearest-neighbor x2 and ordinary8->3.
"""
from pathlib import Path
import torch
from torch import nn
from torch.nn import functional as F
try:
    from .quantization import Quantizer,QConv
except ImportError:
    from quantization import Quantizer,QConv

ARCHITECTURE='stem8_enc16_32_sep5_stddec16_8_3_v1'

class ConvAct(nn.Module):
    def __init__(self,ci,co,k=3,stride=1,groups=1,activate=True):
        super().__init__()
        self.conv=QConv(ci,co,k,stride=stride,padding=k//2,groups=groups,padding_mode='replicate',bias=True)
        self.act=nn.ReLU6() if activate else nn.Identity()
        self.quant=Quantizer(signed=not activate)
    def forward(self,x):return self.quant(self.act(self.conv(x)))

class SepResidual(nn.Module):
    def __init__(self,c=16):
        super().__init__()
        self.dw=ConvAct(c,c,groups=c)
        self.pw=ConvAct(c,c,k=1,activate=False)
        self.add_quant=Quantizer(signed=True)
        self.out_quant=Quantizer()
    def forward(self,x):
        shortcut=self.add_quant(x)
        branch=self.add_quant(self.pw(self.dw(x)))
        return self.out_quant(F.relu6(shortcut+branch))

class Codec16StyleLite(nn.Module):
    input_hw=(144,256)
    def __init__(self):
        super().__init__()
        self.input_quant=Quantizer(fixed_amax=1.)
        self.stem=ConvAct(3,8)
        self.enc1=ConvAct(8,16,stride=2)
        self.enc2=ConvAct(16,32,stride=2)
        self.body=nn.ModuleList([SepResidual(32) for _ in range(5)])
        self.decode_pw=ConvAct(32,16,k=1);self.decode1=ConvAct(16,8)
        self.out=QConv(8,3,3,padding=1,padding_mode='replicate',bias=True)
        self.output_quant=Quantizer(fixed_amax=1.)
        self.quant_enabled=False
        self.set_quantization(False)
    def layer_contract(self):
        layers=[];previous=self.input_quant
        for n in ['stem','enc1','enc2']:
            block=getattr(self,n);layers.append((n+'.conv',block.conv,previous,block.quant));previous=block.quant
        for i,block in enumerate(self.body):
            for n in ['dw','pw']:
                conv=getattr(block,n);layers.append((f'body.{i}.{n}.conv',conv.conv,previous,conv.quant));previous=conv.quant
            previous=block.out_quant
        for n in ['decode_pw','decode1']:
            block=getattr(self,n);layers.append((n+'.conv',block.conv,previous,block.quant));previous=block.quant
        layers.append(('out',self.out,previous,self.output_quant))
        return layers
    def connect_scales(self):
        for _,conv,source,_ in self.layer_contract():conv.input_scale.copy_(source.scale)
    def set_quantization(self,enabled,observing=False):
        self.quant_enabled=bool(enabled)
        for m in self.modules():
            if isinstance(m,Quantizer):m.enabled=enabled;m.observing=observing
            elif isinstance(m,QConv):m.enabled=enabled
    def calibrate(self,images):
        self.eval();self.set_quantization(False,True);seen=0
        with torch.no_grad():
            for image in images:self(image);seen+=1
        if not seen:raise ValueError('Calibration requires representative RGB images, normalized to [0,1].')
        for block in self.body:
            # Values beyond +/-6 cannot change clamp(x+branch,0,6), x in [0,6].
            block.pw.quant.amax.clamp_(max=6.)
            block.add_quant.amax.clamp_(max=6.)
        self.set_quantization(True,False);self.connect_scales()
    def forward(self,x):
        if x.shape[-2]%4 or x.shape[-1]%4:raise ValueError('Image dimensions must be multiples of four.')
        if self.quant_enabled:self.connect_scales()
        x=self.enc2(self.enc1(self.stem(self.input_quant(x))))
        for block in self.body:x=block(x)
        x=self.decode_pw(x)
        x=self.decode1(F.interpolate(x,scale_factor=2,mode='nearest'))
        return self.output_quant(self.out(F.interpolate(x,scale_factor=2,mode='nearest')).clamp(0,1))

def save_checkpoint(path,model,*,trained_for_codec16=False):
    torch.save(dict(architecture=ARCHITECTURE,trained_for_codec16=bool(trained_for_codec16),
        qat=model.quant_enabled,input_hw=list(model.input_hw),state_dict=model.state_dict()),Path(path))

def load_checkpoint(path):
    payload=torch.load(path,map_location='cpu',weights_only=True)
    if payload.get('architecture')!=ARCHITECTURE:raise ValueError('Expected a newly trained Codec16 checkpoint; legacy Starry/Candy are incompatible.')
    model=Codec16StyleLite();model.load_state_dict(payload['state_dict'],strict=True)
    model.set_quantization(payload.get('qat',False));return model,payload
