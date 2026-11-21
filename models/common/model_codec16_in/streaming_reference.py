"""Integer IN reference: delayed layer refresh or exact-current-layer diagnostic.

Both modes require NEW IN-trained conv/scale/affine data. Supplying old no-IN
weights is useful only as an arithmetic fixture, not as a trained IN style.
"""
from pathlib import Path
import math,struct
import torch
from torch.nn import functional as F
from model_codec16.integer_reference import IntegerReference,rounded_shift

def coefficients(s1,s2,n,g,b,e):
    def trunc(a,d):return (abs(a)//d)*(-1 if a<0 else 1)
    if not n or not 0<g<=32767 or not -32768<=b<=32767:raise ValueError('IN coefficient input out of range')
    mean=trunc(s1*256,n);var=max(0,(s2<<16)//n-mean*mean);root=math.isqrt(var+max(e,65536));den=root<<8
    shift=32;mult=(g<<shift)//den
    while mult<0x40000000 and shift<47:shift+=1;mult=(g<<shift)//den
    bias=trunc(b*root,g)-mean
    if not 0<mult<2**31 or not -2**19<=bias<2**19:raise ValueError('IN coefficients do not fit current RTL; do not silently clip')
    return bias,mult,shift

class StreamingINReference(IntegerReference):
    def __init__(self,directory,affine_file):
        super().__init__(directory);raw=Path(affine_file).read_bytes()
        if len(raw)!=3200:raise ValueError('IN15 affine sidecar must be exactly 3200 bytes')
        self.order=list(self.layers)[:15];self.affine={};offset=0;self.next_layer=0;self.stats={};self.exact=False
        for name in self.order:
            channels=self.layers[name][1].shape[0]
            self.affine[name]=[struct.unpack_from('<HhI',raw,offset+8*c) for c in range(channels)];offset+=8*channels
        assert offset==3200
    def _update(self,name,stats):
        sums,squares,n=stats;coefs=[coefficients(int(s1),int(s2),n,*affine) for s1,s2,affine in zip(sums,squares,self.affine[name])]
        # Atomically replace all channel coefficients after every value is valid.
        row,w,b,q=self.layers[name];values=torch.tensor(coefs,dtype=torch.int64);self.layers[name]=(row,w,values[:,0],values[:,1:])
    def conv(self,name,x):
        row,w,b,q=self.layers[name];kh,kw=w.shape[-2:];sh,sw=row['stride'];ph,pw=row['padding'];groups=row['groups']
        oh=(x.shape[-2]+2*ph-kh)//sh+1;ow=(x.shape[-1]+2*pw-kw)//sw+1
        cols=F.unfold(F.pad(x.float(),(pw,pw,ph,ph),mode='replicate'),(kh,kw),stride=(sh,sw)).long().reshape(1,groups,-1,oh*ow)
        acc=torch.matmul(w.reshape(groups,w.shape[0]//groups,-1),cols).reshape(w.shape[0],-1)
        if name!='out':
            a=acc>>8;self.stats[name]=(a.sum(1),a.square().sum(1),a.shape[1])
            if self.exact:self._update(name,self.stats[name]);row,w,b,q=self.layers[name]
        y=rounded_shift((acc+b[:,None])*q[:,0,None],q[:,1,None]);quant=self.quantizers[row['output_quantizer']]
        upper=127 if name=='out' or '.pw.' in name else min(127,self.relu6_limits[row['output_quantizer']])
        return y.clamp(quant['qmin'],upper).reshape(1,w.shape[0],oh,ow)
    def frame(self,u8,*,update=True,exact_current_frame=False):
        if u8.shape[0]!=1:raise ValueError('Streaming state is per video stream; use one frame at a time.')
        self.exact=exact_current_frame;self.stats={};result=super().__call__(u8)
        if update and not self.exact:
            name=self.order[self.next_layer];self._update(name,self.stats[name]);self.next_layer=(self.next_layer+1)%15
        return result
