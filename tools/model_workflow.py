"""原训练网络的四风格推理、24960B导出包重建与原始数据校验；不直接替换当前RTL运行包。"""
from pathlib import Path
import argparse,hashlib,json,shutil,sys,tempfile,struct

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'models/common'))
STYLES=('starry','cubist','abstract','mosaic')
LABELS=dict(zip(STYLES,('星空','立体派','抽象派','马赛克')))

def normalize_manifest(directory,output):
    """只规范化旧打包器的结构标签，保留源元数据和所有数值字节。"""
    directory=Path(directory);output=Path(output);output.mkdir(parents=True,exist_ok=True)
    m=json.loads((directory/'quantization_manifest.json').read_text(encoding='utf-8'))
    assert m['input_hw']==[144,256] and m['channels']==[8,16,32] and m['residual_blocks']==5
    assert m.get('trained_for_in') is True
    for p in directory.glob('*.bin'):shutil.copy2(p,output/p.name)
    m['architecture']='stem8_enc16_32_sep5_stddec16_8_3_v1';m['trained_for_codec16']=True
    (output/'quantization_manifest.json').write_text(json.dumps(m),encoding='utf-8')
    return m

def verify_style(style,output=None):
    from model_codec16.packing import pack
    d=ROOT/'weights'/style
    if output and Path(output).resolve()==d.resolve():raise ValueError('Export into build/ first; do not overwrite the deployed source')
    bundle_path=ROOT/'models'/style/'checkpoints/INT8_tensor_bundle.pt'
    tensor_bundle_matches=None
    if bundle_path.exists():
        import torch
        bundle=torch.load(bundle_path,map_location='cpu',weights_only=False)
        manifest=json.loads((d/'quantization_manifest.json').read_text(encoding='utf-8'))
        weights=bytearray();bias=bytearray();requant=bytearray()
        for layer in manifest['layers']:
            if 'layers' in bundle:
                tensors=bundle['layers'][layer['name']];w=tensors['weight']
                bias.extend(tensors['bias'].numpy().astype('<i4').tobytes())
                requant.extend(tensors['requant'].numpy().astype('<i4').tobytes())
            else:w=bundle['weights_int8'][layer['name']]
            assert w.dtype==torch.int8 and list(w.shape)==layer['weight_shape']
            weights.extend(w.numpy().tobytes())
        assert weights==(d/'weights_int8.bin').read_bytes()
        if 'layers' in bundle:
            assert bias==(d/'bias_int32.bin').read_bytes() and requant==(d/'requant_int32.bin').read_bytes()[:len(requant)]
            affine=bundle['affine_bytes']
        else:affine=bundle['IN15_AFFINE'].numpy().tobytes()
        assert affine==(d/'IN15_TRAINED_AFFINE.bin').read_bytes()
        tensor_bundle_matches=True
    with tempfile.TemporaryDirectory(prefix='ti60_repack_') as temporary:
        working=Path(temporary);m=normalize_manifest(d,working);mapping=pack(working,working)
        for name in ['codec16_rtl_ddr.bin']+[f'codec16_rtl_ddr_u{w}.mem' for w in (32,128,160)]:
            if name.endswith('.mem'):assert (working/name).read_text().split()==(d/name).read_text().split(),(style,name)
            else:assert (working/name).read_bytes()==(d/name).read_bytes(),(style,name)
        affine=(d/'IN15_TRAINED_AFFINE.bin').read_bytes();assert len(affine)==3200
        records=list(struct.iter_unpack('<HhI',affine))
        assert len(records)==400 and all(0<g<=32767 and e>=65536 for g,b,e in records)
        if output:
            output=Path(output);output.mkdir(parents=True,exist_ok=True)
            # 目录可直接交给部署加载器；源清单保持其本来的架构标识。
            for p in d.iterdir():
                if p.is_file():shutil.copy2(p,output/p.name)
            for p in working.glob('codec16_rtl_ddr*'):shutil.copy2(p,output/p.name)
        return {'style':style,'display_name':LABELS[style],'segments':len(mapping['segments']),
                'scan_bytes':24960,'affine_bytes':len(affine),'scan_sha256':hashlib.sha256((d/'codec16_rtl_ddr.bin').read_bytes()).hexdigest(),
                'affine_sha256':hashlib.sha256(affine).hexdigest(),'repacked_byte_identical':True,'INT8_tensor_bundle_matches_export':tensor_bundle_matches}

def load_image(path,resize):
    import numpy as np
    import torch
    from PIL import Image,ImageOps
    image=ImageOps.exif_transpose(Image.open(path)).convert('RGB')
    if image.size==(256,144):array=np.array(image)
    elif resize=='error':raise ValueError('Input must be physical 256x144 RGB; use --resize fit or contain explicitly')
    elif resize=='fit':array=np.array(ImageOps.fit(image,(256,144),Image.Resampling.BILINEAR))
    else:
        scale=min(256/image.width,144/image.height)
        image=image.resize((max(1,round(image.width*scale)),max(1,round(image.height*scale))),Image.Resampling.BILINEAR)
        array=np.array(image);dy=144-array.shape[0];dx=256-array.shape[1]
        array=np.pad(array,((dy//2,dy-dy//2),(dx//2,dx-dx//2),(0,0)),mode='edge')
    return torch.from_numpy(array.copy()).permute(2,0,1)[None].long()

def infer(style,input_path,output,mode,frames=60,resize='error'):
    import numpy as np
    import torch
    from PIL import Image
    torch.set_num_threads(4)
    x=load_image(input_path,resize)
    if mode=='fp32':
        from model_codec16_in.model import load_checkpoint
        checkpoint=ROOT/'models'/style/'checkpoints'/('FP32.pth' if style=='starry' else 'FP32_best.pt')
        m,_=load_checkpoint(checkpoint);m.eval();m.set_quantization(False)
        with torch.inference_mode():y=(m(x.float()/255).clamp(0,1)*255).round().long()
    else:
        from model_codec16_in.streaming_reference import StreamingINReference
        with tempfile.TemporaryDirectory(prefix='ti60_integer_') as temporary:
            d=Path(temporary);normalize_manifest(ROOT/'weights'/style,d)
            reference=StreamingINReference(d,d/'IN15_TRAINED_AFFINE.bin')
            with torch.inference_mode():
                if mode=='int8-current':y=reference.frame(x,exact_current_frame=True)
                else:
                    if frames<1:raise ValueError('frames must be positive')
                    for _ in range(frames):y=reference.frame(x,update=True)
    output=Path(output);output.parent.mkdir(parents=True,exist_ok=True)
    Image.fromarray(y[0].byte().permute(1,2,0).numpy()).save(output)
    return y

def main():
    p=argparse.ArgumentParser(description=__doc__);sub=p.add_subparsers(dest='command',required=True)
    v=sub.add_parser('verify');v.add_argument('--style',choices=(*STYLES,'all'),default='all')
    e=sub.add_parser('export');e.add_argument('--style',choices=STYLES,required=True);e.add_argument('--output',type=Path,required=True)
    i=sub.add_parser('infer');i.add_argument('--style',choices=STYLES,required=True);i.add_argument('--input',type=Path,required=True);i.add_argument('--output',type=Path,required=True)
    i.add_argument('--mode',choices=('fp32','int8-current','int8-history'),default='int8-history');i.add_argument('--frames',type=int,default=60);i.add_argument('--resize',choices=('error','fit','contain'),default='error')
    a=p.parse_args()
    if a.command=='infer':infer(a.style,a.input,a.output,a.mode,a.frames,a.resize);print('Saved',a.output);return
    result=[verify_style(style,a.output if a.command=='export' else None) for style in (STYLES if a.style=='all' else (a.style,))]
    print(json.dumps(result,ensure_ascii=False,indent=2))

if __name__=='__main__':main()
