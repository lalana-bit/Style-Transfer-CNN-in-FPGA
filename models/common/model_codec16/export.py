"""Export a newly trained Codec16 checkpoint. Test fixtures require explicit opt-in."""
from pathlib import Path
import argparse,json,struct,hashlib,shutil
import numpy as np,torch
from PIL import Image
try:
    from .model import load_checkpoint,ARCHITECTURE
    from .quantization import Quantizer
    from .packing import multiplier_shift,pack,update_config
except ImportError:
    from model import load_checkpoint,ARCHITECTURE
    from quantization import Quantizer
    from packing import multiplier_shift,pack,update_config

@torch.inference_mode()
def export(model,metadata,output,allow_test_fixture=False):
    if getattr(model,'has_adaptive_in',False):
        raise ValueError('This is an adaptive-IN graph. Legacy fixed-coefficient export is refused; an IN-aware weight and firmware parameter export is required.')
    if not metadata.get('trained_for_codec16') and not allow_test_fixture:
        raise ValueError('No trained Codec16 weights: export refused. Old Starry/Candy and randomly initialized Codec16 are not deployable.')
    if not model.quant_enabled:raise ValueError('Run representative calibration or QAT before exporting.')
    model.eval();model.connect_scales();out=Path(output);out.mkdir(parents=True,exist_ok=True)
    names={id(m):name for name,m in model.named_modules()}
    q={names[id(m)]:dict(scale=float(m.scale),qmin=-127 if m.signed else 0,qmax=127) for m in model.modules() if isinstance(m,Quantizer)}
    if any(float(m.amax)<=0 for m in model.modules() if isinstance(m,Quantizer)):raise ValueError('Unobserved quantizer; supply representative calibration data')
    order=list(q);controls=bytearray();limits={}
    for name,entry in q.items():
        limit=127 if name in ['input_quant','output_quant'] else min(2**31-1,round(6./entry['scale']))
        limits[name]=limit;controls.extend(struct.pack('<iiii',entry['qmin'],entry['qmax'],limit,0))
    weights=bytearray();bias=bytearray();requant=bytearray();layers=[]
    for name,conv,source,dest in model.layer_contract():
        qw,qb,ws=conv.integer_parameters();qw=qw.round().to(torch.int8).numpy();qb=qb.round().to(torch.int64).numpy()
        if (qb < -2**31).any() or (qb>=2**31).any():raise ValueError('INT32 bias overflow')
        req=b''.join(struct.pack('<ii',*multiplier_shift(float(source.scale*scale/dest.scale))) for scale in ws)
        raw=qw.tobytes();bb=qb.astype('<i4').tobytes()
        layers.append(dict(name=name,weight_shape=list(qw.shape),groups=conv.groups,stride=list(conv.stride),padding=list(conv.padding),
            padding_mode='replicate',upsample_before=(2 if name in ['decode1.conv','out'] else 1),output_quantizer=names[id(dest)],input_quantizer=names[id(source)],
            weight_offset=len(weights),weight_bytes=len(raw),bias_offset=len(bias),bias_bytes=len(bb),requant_offset=len(requant),requant_bytes=len(req)))
        weights.extend(raw);bias.extend(bb);requant.extend(req)
    conversions={};previous=model.enc2.quant
    for i,block in enumerate(model.body):
        for key,source,dest in [('shortcut_to_add',previous,block.add_quant),('branch_to_add',block.pw.quant,block.add_quant),('add_to_output',block.add_quant,block.out_quant)]:
            mult,shift=multiplier_shift(float(source.scale/dest.scale));conversions[f'body.{i}.'+key]=dict(offset=len(requant),multiplier=mult,shift=shift,
                source=names[id(source)],destination=names[id(dest)]);requant.extend(struct.pack('<ii',mult,shift))
        previous=block.out_quant
    inp=np.rint(np.arange(256)/255./float(model.input_quant.scale)).clip(0,127).astype(np.int8)
    output_lut=np.rint(np.arange(128)*float(model.output_quant.scale)*255.).clip(0,255).astype(np.uint8)
    files={'weights_int8.bin':weights,'bias_int32.bin':bias,'requant_int32.bin':requant,'activation_control_int32.bin':controls,
        'input_u8_to_i8_lut.bin':inp.tobytes(),'output_i8_to_u8_lut.bin':output_lut.tobytes()}
    for name,data in files.items():(out/name).write_bytes(data)
    manifest=dict(architecture=ARCHITECTURE,model='Codec16StyleLite',input_hw=[144,256],channels=[8,16,32],residual_blocks=5,
        variant='stem8_enc16_32_sep5_stddec16_8_3',upsample_factors=[2,2],pixel_shuffle=1,decoder_channels=[16,8,3],decoder_upsample_mode='nearest',padding_mode='replicate',head_kernel=3,layers=layers,quantizers=q,
        residual_conversions=conversions,activation_control_order=order,relu6_limits=limits,
        trained_for_codec16=bool(metadata.get('trained_for_codec16')),synthetic_fixture=not bool(metadata.get('trained_for_codec16')))
    (out/'quantization_manifest.json').write_text(json.dumps(manifest,indent=2))
    shutil.copy2(Path(__file__).with_name('integer_reference.py'),out/'integer_reference.py')
    return pack(out,out)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--checkpoint',required=True);p.add_argument('--output',required=True)
    p.add_argument('--calibration-dir');p.add_argument('--config',help='Update cnn_model_config.vh; requires a trained checkpoint')
    p.add_argument('--allow-test-fixture',action='store_true');args=p.parse_args()
    model,meta=load_checkpoint(args.checkpoint)
    if args.calibration_dir:
        paths=[f for f in Path(args.calibration_dir).rglob('*') if f.suffix.lower() in ['.png','.jpg','.jpeg','.bmp']]
        def images():
            for f in paths:
                a=np.asarray(Image.open(f).convert('RGB').resize((256,144),Image.Resampling.BILINEAR)).copy()
                yield torch.from_numpy(a).permute(2,0,1).float().unsqueeze(0)/255.
        model.calibrate(images())
    result=export(model,meta,args.output,args.allow_test_fixture)
    if args.config:update_config(args.config,result,args.output)
    print(json.dumps(result,indent=2))
    print('No Flash images or CPU CRC tables were changed. Match both styles, firmware and BIT before board deployment.')
if __name__=='__main__':main()
