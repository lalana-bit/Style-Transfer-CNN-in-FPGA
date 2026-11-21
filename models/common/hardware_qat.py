"""IN15 hardware-aware fake quantization with exact integer forward arithmetic.

All original layers/sites/parameters remain in place. IN statistics use acc>>8,
Q8 mean, Q16 variance, integer sqrt, positive INT31 multiplier, INT20 bias and
round-to-nearest-even shifts, matching the supplied RV32I/RTL reference.
"""
import types,math,struct,json
from pathlib import Path
import torch,numpy as np
from torch.nn import functional as F
from model_codec16_in.model import Codec16IN
from model_codec16_in.model import IN_SITES,canonicalize_gamma,ARCHITECTURE
from model_codec16.quantization import Quantizer,QConv

def ste_floor(x):return x+(x.floor()-x).detach()
def ste_trunc(x):return x+(x.trunc()-x).detach()
def ste_round(x):return x+(x.round()-x).detach()

def rne_shift(v,s):
 a=v.abs();q=a>>s;r=a&((torch.ones_like(s)<<s)-1);half=torch.ones_like(s)<<(s-1)
 return (q+((r>half)|((r==half)&((q&1)!=0))).long())*v.sign()

def coefficients_tensor(mean,var,g,b,eps):
 """Integer values in INT64; same coefficient algorithm as the archive."""
 root=torch.sqrt((var+eps).double()).floor().long().clamp_min(1);den=root<<8
 bias=torch.div(b*root,g,rounding_mode='trunc')-mean
 shift=(30+torch.ceil(torch.log2(den.double()/g.double()))).long().clamp(32,47)
 mult=torch.div(g<<shift,den,rounding_mode='floor')
 up=(mult<0x40000000)&(shift<47);shift=shift+up.long();mult=torch.div(g<<shift,den,rounding_mode='floor')
 # Correct the floating log estimate at integer boundaries, if necessary.
 prev=torch.div(g<<(shift-1),den,rounding_mode='floor');down=(shift>32)&(prev>=0x40000000);shift-=down.long();mult=torch.div(g<<shift,den,rounding_mode='floor')
 return bias,mult,shift,root

def configure(model,record=None):
 """Call after loading a QAT checkpoint; numeric wrappers are not serialized."""
 torch.backends.cuda.matmul.allow_tf32=False;torch.backends.cudnn.allow_tf32=False
 for q in model.modules():
  if isinstance(q,Quantizer):q.amax.fill_(1. if q.fixed_amax==1. else 6.);q.enabled=True;q.observing=False
 model.set_quantization(True,False);model.connect_scales()
 for site in IN_SITES:
  block=model.get_submodule(site);conv=block.conv;dest=block.quant
  # Convolution bias cancels under exact IN; RTL statistics use raw MAC sums.
  with torch.no_grad():conv.bias.zero_()
  conv.bias.requires_grad_(False)
  def forward(norm,z,_conv=conv,_dest=dest,_site=site):
   ws=_conv.weight.detach().abs().flatten(1).amax(1).clamp_min(1e-7)/127
   unit=(_conv.input_scale*ws).double()[None,:,None,None];acc=ste_round(z.double()/unit)
   a=ste_floor(acc/256);n=a.shape[-2]*a.shape[-1]
   mean=ste_trunc(a.sum((2,3),keepdim=True)*256/n)
   var=(ste_floor(a.square().sum((2,3),keepdim=True)*65536/n)-mean.square()).clamp_min(0)
   eps=torch.maximum(torch.full_like(unit,65536),torch.round(norm.eps/unit.square())).long()
   sy=_dest.scale.detach().double();g=ste_round(norm.weight.double()/sy*256);b=ste_round(norm.bias.double()/sy*256)
   gi=g.detach().long().clamp(1,32767)[None,:,None,None];bi=b.detach().long().clamp(-32768,32767)[None,:,None,None]
   bias,mult,shift,root=coefficients_tensor(mean.detach().long(),var.detach().long(),gi,bi,eps)
   v=(acc.detach().long()+bias)*mult;code=rne_shift(v,shift)
   root_ste=ste_floor(torch.sqrt(var+eps.double())).clamp_min(1)
   approx=(g[None,:,None,None]/256*sy)*((acc-mean)/root_ste)+(b[None,:,None,None]/256*sy)
   exact=code.double()*sy;result=approx+(exact-approx).detach()
   if record is not None:
    record[_site]={'bias':bias.detach().cpu(),'multiplier':mult.detach().cpu(),'shift':shift.detach().cpu(),'root':root.detach().cpu(),'g':gi.detach().cpu(),'b':bi.detach().cpu(),'eps':eps.detach().cpu()}
   return result.to(z.dtype)
  block.norm.forward=types.MethodType(forward,block.norm)
 out=model.out;output_quant=model.output_quant
 def output_forward(conv,x):
  z=QConv.forward(conv,x);ws=conv.weight.detach().abs().flatten(1).amax(1).clamp_min(1e-7)/127
  unit=(conv.input_scale*ws).double()[None,:,None,None];sy=output_quant.scale.detach().double();mant,exponent=torch.frexp(unit/sy)
  mult=torch.round(mant*(1<<31)).long();overflow=mult==(1<<31);mult=torch.where(overflow,mult//2,mult);shift=31-exponent.long()-overflow.long()
  acc=torch.round(z.double()/unit).long();code=rne_shift(acc*mult,shift);exact=code.double()*sy
  if record is not None:
   bias=torch.round(conv.bias.detach().double()/unit.flatten()).long();record['out']={'bias':bias.cpu(),'multiplier':mult.cpu(),'shift':shift.cpu()}
  return z+(exact.to(z.dtype)-z).detach()
 out.forward=types.MethodType(output_forward,out)
 return model

@torch.no_grad()
def constrain_affine(model):
 for site in IN_SITES:
  block=model.get_submodule(site);sy=float(block.quant.scale);block.norm.weight.clamp_(sy/256,32767*sy/256);block.norm.bias.clamp_(-32768*sy/256,32767*sy/256)

def load_model(path,device='cpu',record=None):
 p=torch.load(path,map_location=device,weights_only=False);m=Codec16IN().to(device);m.load_state_dict(p['state_dict']);return configure(m,record),p

def scalar_coefficients(s1,s2,n,g,b,eps):
 def trunc(a,d):return (abs(a)//d)*(-1 if a<0 else 1)
 mean=trunc(s1*256,n);var=max(0,(s2<<16)//n-mean*mean);root=math.isqrt(var+max(eps,65536));den=root<<8;shift=32;mult=(g<<shift)//den
 while mult<0x40000000 and shift<47:shift+=1;mult=(g<<shift)//den
 bias=trunc(b*root,g)-mean
 if not 0<mult<2**31 or not -2**19<=bias<2**19:raise ValueError('IN coefficients exceed RTL range')
 return bias,mult,shift
