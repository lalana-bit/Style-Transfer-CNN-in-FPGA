"""Integer-only Codec16 golden model; CPU tensor gathering uses exact INT8 values."""
from pathlib import Path
import json,numpy as np,torch
from torch.nn import functional as F

def rounded_shift(value,shift):
    a=value.abs();q=a>>shift;r=a&((torch.ones_like(shift)<<shift)-1);half=torch.ones_like(shift)<<(shift-1)
    return (q+((r>half)|((r==half)&((q&1)!=0))).long())*value.sign()

class IntegerReference:
    def __init__(self,directory):
        d=Path(directory);self.directory=d;self.manifest=json.loads((d/'quantization_manifest.json').read_text())
        if self.manifest['architecture']!='stem8_enc16_32_stdres1_sep4_stddec16_8_3_v1':raise ValueError('Wrong architecture')
        self.layers={};weights=(d/'weights_int8.bin').read_bytes();bias=(d/'bias_int32.bin').read_bytes();req=(d/'requant_int32.bin').read_bytes()
        for row in self.manifest['layers']:
            w=torch.from_numpy(np.frombuffer(weights,np.int8,count=row['weight_bytes'],offset=row['weight_offset']).copy().reshape(row['weight_shape'])).long()
            b=torch.from_numpy(np.frombuffer(bias,'<i4',count=row['bias_bytes']//4,offset=row['bias_offset']).copy()).long()
            q=torch.from_numpy(np.frombuffer(req,'<i4',count=row['requant_bytes']//4,offset=row['requant_offset']).copy().reshape(-1,2)).long()
            self.layers[row['name']]=(row,w,b,q)
        self.quantizers=self.manifest['quantizers'];self.conversions=self.manifest['residual_conversions']
        self.relu6_limits=self.manifest['relu6_limits'];self.input_lut=torch.from_numpy(np.frombuffer((d/'input_u8_to_i8_lut.bin').read_bytes(),np.int8).copy()).long()
        self.output_lut=torch.from_numpy(np.frombuffer((d/'output_i8_to_u8_lut.bin').read_bytes(),np.uint8).copy()).long()
    def conv(self,name,x):
        row,w,b,q=self.layers[name];kh,kw=w.shape[-2:];sh,sw=row['stride'];ph,pw=row['padding'];groups=row['groups']
        oh=(x.shape[-2]+2*ph-kh)//sh+1;ow=(x.shape[-1]+2*pw-kw)//sw+1
        pad=F.pad(x.float(),(pw,pw,ph,ph),mode='replicate')
        col=F.unfold(pad,(kh,kw),stride=(sh,sw)).long().reshape(x.shape[0],groups,-1,oh*ow)
        acc=torch.matmul(w.reshape(groups,w.shape[0]//groups,-1),col).reshape(x.shape[0],w.shape[0],-1)+b.reshape(1,-1,1)
        y=rounded_shift(acc*q[:,0].reshape(1,-1,1),q[:,1].reshape(1,-1,1))
        quant=self.quantizers[row['output_quantizer']];upper=127
        if name!='out' and '.pw.' not in name and '.conv2.' not in name:upper=min(upper,self.relu6_limits[row['output_quantizer']])
        return y.clamp(quant['qmin'],upper).reshape(x.shape[0],w.shape[0],oh,ow)
    def convert(self,name,x,clip=True):
        p=self.conversions[name];y=rounded_shift(x*p['multiplier'],torch.tensor(p['shift']))
        if clip:
            q=self.quantizers[p['destination']];y=y.clamp(q['qmin'],q['qmax'])
        return y
    def forward_codes(self,u8):
        x=self.input_lut[u8.long()]
        for n in ['stem.conv','enc1.conv','enc2.conv']:x=self.conv(n,x)
        for i in range(5):
            pre=f'body.{i}.';shortcut=self.convert(pre+'shortcut_to_add',x)
            first,second=('conv1.conv','conv2.conv') if i==0 else ('dw.conv','pw.conv')
            branch=self.convert(pre+'branch_to_add',self.conv(pre+second,self.conv(pre+first,x)))
            x=self.convert(pre+'add_to_output',(shortcut+branch).clamp(0,self.relu6_limits[pre+'add_quant']))
        x=self.conv('decode_pw.conv',x)
        x=self.conv('decode1.conv',x.repeat_interleave(2,2).repeat_interleave(2,3))
        return self.conv('out',x.repeat_interleave(2,2).repeat_interleave(2,3))
    def __call__(self,u8):return self.output_lut[self.forward_codes(u8)]
