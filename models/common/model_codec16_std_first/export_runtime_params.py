"""Export trained affine IN parameters for the RV32I runtime (not conv weights).

The supplied quantization manifest/weight binary must already correspond to the
new IN checkpoint. Legacy no-IN checkpoints are rejected by the model loader.
"""
import argparse,json,math,hashlib,struct,zlib
from pathlib import Path
import numpy as np
from .model import load_checkpoint,IN_SITES,canonicalize_gamma

def main():
    p=argparse.ArgumentParser();p.add_argument('--checkpoint',required=True);p.add_argument('--quantization-dir',required=True);p.add_argument('--header',required=True);a=p.parse_args()
    model,meta=load_checkpoint(a.checkpoint)
    if not meta.get('trained_for_in'):raise ValueError('Untrained IN interface fixtures cannot enable firmware IN.')
    model=canonicalize_gamma(model)
    qdir=Path(a.quantization_dir);q=json.loads((qdir/'quantization_manifest.json').read_text());weights=(qdir/'weights_int8.bin').read_bytes()
    contract=model.layer_contract();assert len(q['layers'])==16 and len(contract)==16
    gamma=[];beta=[];epsilon=[]
    for i,(name,conv,_,_) in enumerate(contract):
        row=q['layers'][i];w=conv.weight.detach().numpy();ws=np.maximum(np.max(np.abs(w),axis=(1,2,3)),1e-7)/127
        qw=np.rint(w/ws[:,None,None,None]).clip(-127,127).astype(np.int8)
        if row['name']!=name or list(qw.shape)!=row['weight_shape'] or qw.tobytes()!=weights[row['weight_offset']:row['weight_offset']+row['weight_bytes']]:raise ValueError('Quantized convolution weights differ from the IN checkpoint: '+name)
        if i==15:continue
        module=model.get_submodule(IN_SITES[i]);sy=q['quantizers'][row['output_quantizer']]['scale'];sx=q['quantizers'][row['input_quantizer']]['scale']
        g=np.rint(module.norm.gamma.detach().numpy()/sy*256).astype(np.int64);b=np.rint(module.norm.beta.detach().numpy()/sy*256).astype(np.int64)
        eps=np.maximum(65536,np.rint(module.norm.eps/np.square(sx*ws*256)*65536)).astype(np.int64)
        if np.any((g<=0)|(g>32767)|(b<-32768)|(b>32767)|(eps>2**32-1)):raise ValueError('IN affine/epsilon exceeds runtime format; retrain/recalibrate: '+name)
        gamma.append(g.tolist());beta.append(b.tolist());epsilon.append(eps.tolist())
    target=Path(a.header);target.parent.mkdir(parents=True,exist_ok=True)
    raw=b''.join(struct.pack('<HhI',g,b,e) for gs,bs,es in zip(gamma,beta,epsilon) for g,b,e in zip(gs,bs,es));assert len(raw)==3200
    target.with_suffix('.bin').write_bytes(raw)
    text='#ifndef CNN_IN_PARAMS_H\n#define CNN_IN_PARAMS_H\n#define CNN_IN_RUNTIME_TRAINED 1\n#define CNN_IN_NODES 15u\n#define CNN_IN_AFFINE_FLASH_OFFSET 0x00420000u\n#define CNN_IN_AFFINE_BYTES 3200u\n'+f'#define CNN_IN_AFFINE_CRC32 0x{zlib.crc32(raw):08x}u\n#endif\n'
    target.write_text(text,encoding='utf-8')
    target.with_suffix('.manifest.json').write_text(json.dumps({'checkpoint_sha256':hashlib.sha256(Path(a.checkpoint).read_bytes()).hexdigest(),'weights_sha256':hashlib.sha256(weights).hexdigest(),'all_15_IN_sites':True,'STAT_SHIFT':8,'header_only_not_complete_weight_export':True,'seed_coefficients_and_style_bank_CRCs_must_match':True},indent=2))
    print(target)
if __name__=='__main__':main()
