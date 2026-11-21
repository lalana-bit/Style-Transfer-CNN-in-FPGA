"""IN-aware export primitives; no source-archive execution or global paths."""
from pathlib import Path
import json, struct, hashlib
import numpy as np
import torch
from torch.nn import functional as F
from model_codec16_in.model import IN_SITES, ARCHITECTURE
from model_codec16.quantization import Quantizer
from model_codec16.packing import multiplier_shift
from model_codec16.integer_reference import rounded_shift
from model_codec16_in.streaming_reference import StreamingINReference
sha=lambda b:hashlib.sha256(b).hexdigest()
class FastIN(StreamingINReference):
    def conv(self,name,x):
        row,w,b,q=self.layers[name];ph,pw=row['padding']
        # CPU FP32 sums integers exactly: all products and partial sums fit
        # INT24, hence below FP32's exact-integer 24-bit significand limit.
        acc=F.conv2d(F.pad(x.float(),(pw,pw,ph,ph),mode='replicate'),w.float(),stride=row['stride'],groups=row['groups']).long()[0]
        h,ww=acc.shape[-2:];acc=acc.reshape(acc.shape[0],-1)
        if name!='out':
            a=acc>>8;self.stats[name]=(a.sum(1),a.square().sum(1),a.shape[1])
            if self.exact:self._update(name,self.stats[name]);row,w,b,q=self.layers[name]
        y=rounded_shift((acc+b[:,None])*q[:,0,None],q[:,1,None]);quant=self.quantizers[row['output_quantizer']]
        upper=127 if name=='out' or '.pw.' in name else min(127,self.relu6_limits[row['output_quantizer']])
        return y.clamp(quant['qmin'],upper).reshape(1,w.shape[0],h,ww)

def write_export(m,meta,directory,checkpoint):
    Q=Path(directory);SRC=Path(checkpoint).parent
    Q.mkdir(parents=True,exist_ok=True)
    names={id(v):n for n,v in m.named_modules()}
    quant={names[id(v)]:dict(scale=float(v.scale),qmin=-127 if v.signed else 0,qmax=127) for v in m.modules() if isinstance(v,Quantizer)}
    limits={n:(127 if n in ['input_quant','output_quant'] else min(2**31-1,round(6/e['scale']))) for n,e in quant.items()}
    controls=b''.join(struct.pack('<iiii',e['qmin'],e['qmax'],limits[n],0) for n,e in quant.items())
    weights=bytearray();bias=bytearray();requant=bytearray();layers=[];affine=bytearray()
    m.connect_scales()
    for i,(name,conv,sx,sy) in enumerate(m.layer_contract()):
        qw,qb,ws=conv.integer_parameters();qw=qw.to(torch.int8).numpy();qb=qb.to(torch.int64).numpy()
        if i<15:qb[:]=0
        assert np.max(np.abs(qb))<2**19
        req=b''.join(struct.pack('<ii',*multiplier_shift(float(sx.scale*w/sy.scale))) for w in ws)
        raw=qw.tobytes();bb=qb.astype('<i4').tobytes()
        layers.append(dict(name=name,weight_shape=list(qw.shape),groups=conv.groups,stride=list(conv.stride),padding=list(conv.padding),padding_mode='replicate',
            upsample_before=2 if name in ['decode1.conv','out'] else 1,output_quantizer=names[id(sy)],input_quantizer=names[id(sx)],
            weight_scales=ws.tolist(),weight_offset=len(weights),weight_bytes=len(raw),bias_offset=len(bias),bias_bytes=len(bb),requant_offset=len(requant),requant_bytes=len(req)))
        weights.extend(raw);bias.extend(bb);requant.extend(req)
        if i<15:
            norm=m.get_submodule(IN_SITES[i]).norm
            gg=np.rint(norm.gamma.detach().numpy()/float(sy.scale)*256).astype(np.int64)
            beta=np.rint(norm.beta.detach().numpy()/float(sy.scale)*256).astype(np.int64)
            eps=np.maximum(65536,np.rint(norm.eps/np.square(float(sx.scale)*ws.numpy()*256)*65536)).astype(np.int64)
            assert np.all((gg>0)&(gg<=32767)&(beta>=-32768)&(beta<=32767)&(eps<=0xffffffff)),(name,gg,beta,eps)
            affine.extend(b''.join(struct.pack('<HhI',int(g),int(b),int(e)) for g,b,e in zip(gg,beta,eps)))
    conversions={};previous=m.enc2.quant
    for i,block in enumerate(m.body):
        for key,source,dest in [('shortcut_to_add',previous,block.add_quant),('branch_to_add',block.pw.quant,block.add_quant),('add_to_output',block.add_quant,block.out_quant)]:
            mult,shift=multiplier_shift(float(source.scale/dest.scale))
            conversions[f'body.{i}.'+key]=dict(offset=len(requant),multiplier=mult,shift=shift,source=names[id(source)],destination=names[id(dest)])
            requant.extend(struct.pack('<ii',mult,shift))
        previous=block.out_quant
    inp=np.rint(np.arange(256)/255/float(m.input_quant.scale)).clip(0,127).astype(np.int8)
    out=np.rint(np.arange(128)*float(m.output_quant.scale)*255).clip(0,255).astype(np.uint8)
    files={'weights_int8.bin':weights,'bias_int32.bin':bias,'requant_int32.bin':requant,'activation_control_int32.bin':controls,
        'input_u8_to_i8_lut.bin':inp.tobytes(),'output_i8_to_u8_lut.bin':out.tobytes(),'IN15_TRAINED_AFFINE.bin':affine}
    for n,data in files.items():(Q/n).write_bytes(data)
    assert len(affine)==3200
    manifest=dict(architecture='stem8_enc16_32_sep5_stddec16_8_3_v1',trained_architecture=ARCHITECTURE,normalization='adaptive_history_IN15',
        model='Codec16IN',input_hw=[144,256],channels=[8,16,32],residual_blocks=5,layers=layers,quantizers=quant,
        residual_conversions=conversions,relu6_limits=limits,activation_control_order=list(quant),trained_for_in=True,trained_for_codec16=True,synthetic_fixture=False,
        checkpoint_sha256=sha(Path(checkpoint).read_bytes()),quantization='post_training_INT8_per_output_channel_weights',
        IN_conv_bias_removed=True,calibration_inputs=[p.name for p in sorted((SRC/'samples').glob('*_input.png'))],calibration_brightness=[0.5,1,1.5])
    (Q/'quantization_manifest.json').write_text(json.dumps(manifest,indent=2))
    return manifest
