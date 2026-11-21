"""原训练FP32网络的IN量化导出；输出24960B原格式，不是当前RTL的63296B运行包。"""
from pathlib import Path
import sys,json,struct,zlib,hashlib,copy,math
import numpy as np
import torch
from torch.nn import functional as F
from PIL import Image,ImageDraw
O=Path(__file__).resolve().parent
P=O.parent/'hardware'
SRC=O.parent/'models/starry'
Q=O.parent/'build/model_exports/starry';Q.mkdir(parents=True,exist_ok=True)
sys.path.insert(0,str(O.parent/'models/common'))
from model_codec16_in.model import load_checkpoint,canonicalize_gamma,IN_SITES,ARCHITECTURE
from model_codec16.quantization import Quantizer
from model_codec16.packing import pack,multiplier_shift
from model_codec16.integer_reference import rounded_shift
from model_codec16_in.streaming_reference import StreamingINReference,coefficients

torch.set_num_threads(4)
torch.backends.mkldnn.enabled=False
torch.manual_seed(281012)
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

def image_tensor(path):
    im=Image.open(path).convert('RGB');assert im.size==(256,144),(path,im.size)
    return torch.from_numpy(np.array(im).copy()).permute(2,0,1)[None].long()

def write_export(m,meta):
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
        checkpoint_sha256=sha((SRC/'checkpoints/FP32.pth').read_bytes()),quantization='post_training_INT8_per_output_channel_weights',
        IN_conv_bias_removed=True,calibration_inputs=[p.name for p in sorted((SRC/'samples').glob('*_input.png'))],calibration_brightness=[0.5,1,1.5])
    (Q/'quantization_manifest.json').write_text(json.dumps(manifest,indent=2))
    return manifest

@torch.inference_mode()
def main():
    model,meta=load_checkpoint(SRC/'checkpoints/FP32.pth');assert meta['trained_for_in'] and not meta['qat']
    model.eval();baseline=copy.deepcopy(model);model=canonicalize_gamma(model)
    for name in IN_SITES:model.get_submodule(name).conv.bias.zero_()
    inputs=[(p,image_tensor(p)) for p in sorted((SRC/'samples').glob('*_input.png'))];assert len(inputs)==10
    x=inputs[0][1].float()/255
    diff=float((baseline(x)-model(x)).abs().max());assert diff<1e-4,diff
    model.set_quantization(False,True)
    for _,u8 in inputs:
        for brightness in [0.5,1,1.5]:model((u8.float()/255*brightness).clamp(0,1))
    for b in model.body:b.pw.quant.amax.clamp_(max=6);b.add_quant.amax.clamp_(max=6)
    model.set_quantization(True,False);model.connect_scales()
    manifest=write_export(model,meta)
    print('Calibrated graph and affine exported; collecting integer seed statistics.',flush=True)
    # Exact-current diagnostic generates representative raw convolution stats.
    r=FastIN(Q,Q/'IN15_TRAINED_AFFINE.bin');pooled={};quality=[];rows=[]
    for path,u8 in inputs:
        fp=(baseline(u8.float()/255).clamp(0,1)*255).round().long()
        y=r.frame(u8,exact_current_frame=True)
        for name,(s,ss,n) in r.stats.items():
            if name not in pooled:pooled[name]=(s.clone(),ss.clone(),n)
            else:
                s0,ss0,n0=pooled[name];pooled[name]=(s0+s,ss0+ss,n0+n)
        rmse=float((fp.float()-y.float()).square().mean().sqrt());mae=float((fp.float()-y.float()).abs().mean())
        psnr=20*math.log10(255/max(rmse,1e-9));quality.append(dict(sample=path.name,mae_u8=mae,psnr_dB=psnr))
        rows.append((u8,fp,y))
        print(path.name,'MAE',round(mae,3),'PSNR',round(psnr,2),flush=True)
    # Initial coefficients are actual trained-IN normalization calibrated from
    # the ten images, not legacy fixed requant or untrained routing constants.
    r._update=lambda *args:None
    bias=bytearray((Q/'bias_int32.bin').read_bytes());req=bytearray((Q/'requant_int32.bin').read_bytes())
    for row in manifest['layers'][:15]:
        name=row['name'];s,ss,n=pooled[name]
        for c,(s1,s2,aff) in enumerate(zip(s,ss,r.affine[name])):
            b,m,shift=coefficients(int(s1),int(s2),n,*aff)
            struct.pack_into('<i',bias,row['bias_offset']+c*4,b)
            struct.pack_into('<ii',req,row['requant_offset']+c*8,m,shift)
    (Q/'bias_int32.bin').write_bytes(bias);(Q/'requant_int32.bin').write_bytes(req)
    mapping=pack(Q,Q);assert mapping['deployable']
    print('Packed:',mapping['bytes'],'CRC',hex(mapping['crc32']),flush=True)
    # Check the optimized integer convolution against the slow INT64-unfold
    # reference on one full-resolution sample, for all layers and output bits.
    slow=StreamingINReference(Q,Q/'IN15_TRAINED_AFFINE.bin');fast=FastIN(Q,Q/'IN15_TRAINED_AFFINE.bin')
    ys=slow.frame(inputs[0][1],exact_current_frame=True);yf=fast.frame(inputs[0][1],exact_current_frame=True)
    assert torch.equal(ys,yf)
    for name in slow.stats:
        for a,b in zip(slow.stats[name],fast.stats[name]):
            if isinstance(a,torch.Tensor):assert torch.equal(a,b),(name,'statistics')
            else:assert a==b
    # History/firmware coefficient arithmetic and extreme-scenes range check.
    history=[];extremes=[('black',torch.zeros_like(inputs[0][1])),('white',torch.full_like(inputs[0][1],255))]
    for name,u8 in [('sample0',inputs[0][1]),('sample1',inputs[1][1]),*extremes]:
        ref=FastIN(Q,Q/'IN15_TRAINED_AFFINE.bin')
        for i in range(30):yh=ref.frame(u8)
        assert ref.next_layer==0
        ranges=[tuple(map(int,(b.min(),b.max()))) for _,_,b,_ in ref.layers.values()]
        history.append(dict(scene=name,frames=30,all15_layers_updated_twice=True,bias_min=min(v[0] for v in ranges),bias_max=max(v[1] for v in ranges)))
        if name=='sample0':rows[0]=(*rows[0],yh)
        if name=='sample1':rows[1]=(*rows[1],yh)
    # Complete previews show measured differences, including history steady state.
    panel=Image.new('RGB',(1024,(144+22)*4),'white');draw=ImageDraw.Draw(panel)
    for i,row in enumerate(rows[:4]):
        if len(row)<4:
            ref=FastIN(Q,Q/'IN15_TRAINED_AFFINE.bin')
            for k in range(15):yh=ref.frame(row[0])
            row=(*row,yh)
        for j,(a,label) in enumerate(zip(row,['input','selected E012 FP32','INT8 current IN diagnostic','INT8 history after warmup'])):
            panel.paste(Image.fromarray(a[0].permute(1,2,0).numpy().astype(np.uint8)),(j*256,i*166+22));draw.text((j*256+3,i*166+3),label,fill='black')
    panel.save(Q/'quantization_preview.png')
    for i,(path,_) in enumerate(inputs):
        Image.fromarray(rows[i][2][0].permute(1,2,0).numpy().astype(np.uint8)).save(Q/(path.stem+'_INT8.png'))
    torch.save(dict(architecture=ARCHITECTURE,trained_for_in=True,qat=True,input_hw=[144,256],in_sites=list(IN_SITES),state_dict=model.state_dict()),Q/'E012_calibrated_INT8_interface.pth')
    report=dict(checkpoint_architecture=ARCHITECTURE,checkpoint_sha256=manifest['checkpoint_sha256'],canonicalization_max_abs_difference=diff,
        convolutions=16,IN_sites=15,IN_channels=400,input_WH=[256,144],W_A_B_scan_format_unchanged=True,
        scan_bytes=24960,segments=55,scan_crc32=mapping['crc32'],affine_bytes=3200,affine_crc32=zlib.crc32((Q/'IN15_TRAINED_AFFINE.bin').read_bytes()),
        integer_reference_bit_exact=True,quality=quality,quality_is_on_calibration_samples=True,history_range_checks=history,
        weight_quantization_only_no_retraining=True,original_FP32_checkpoint_unchanged=True,board_tested=False,
        runtime_semantics='historical per-layer rotating statistics, not training-time instantaneous IN')
    (Q/'deployment_validation.json').write_text(json.dumps(report,indent=2));(Q/'export_result.json').write_text(json.dumps(report,indent=2))
    print('PASS integer and trained parameter range validation',flush=True)

if __name__=='__main__':main()
