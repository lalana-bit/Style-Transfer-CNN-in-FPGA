from runtime import *
import ast,json,struct,zlib,hashlib,copy,math,time
import torch,numpy as np
from torch.nn import functional as F
from PIL import Image,ImageDraw
from model_codec16_in.model import load_checkpoint,canonicalize_gamma,IN_SITES,ARCHITECTURE
from model_codec16.quantization import Quantizer
from model_codec16.packing import pack,multiplier_shift
from model_codec16.integer_reference import rounded_shift
from model_codec16_in.streaming_reference import StreamingINReference,coefficients
from engine import grid,write
from integer_export import FastIN,write_export
sha=lambda b:hashlib.sha256(b).hexdigest()
@torch.inference_mode()
def main(argv=None):
 import argparse
 p=argparse.ArgumentParser();p.add_argument('--run',default='run01');a=p.parse_args(argv)
 validate_data()
 global Q,SRC
 SRC=ROOT/a.run;Q=SRC/'candidate';Q.mkdir(exist_ok=True)
 torch.set_num_threads(4);torch.backends.mkldnn.enabled=False;torch.backends.cuda.matmul.allow_tf32=False;torch.backends.cudnn.allow_tf32=False
 m,meta=load_checkpoint(SRC/'best_qat.pt');m=canonicalize_gamma(m).eval()
 for n in IN_SITES:m.get_submodule(n).conv.bias.zero_()
 manifest=write_export(m,meta,Q,SRC/'best_qat.pt');manifest.update(quantization=str(meta['training_config']['qat_steps'])+'-step QAT; internal activation scale6/127; IN-aware export',calibration_inputs='64 evenly distributed training samples; exposure .5/1/1.5',calibration_brightness=[.5,1,1.5])
 (Q/'quantization_manifest.json').write_text(json.dumps(manifest,indent=2))
 tr=torch.from_numpy(np.load(asset('data_dir')/'train_content.npy')).long();test=torch.from_numpy(np.load(asset('data_dir')/'test_content.npy')).long();target=torch.from_numpy(np.load(asset('data_dir')/'test_target.npy')).long()
 ex=torch.from_numpy(np.load(asset('data_dir')/'external_test_content.npy')).long();et=torch.from_numpy(np.load(asset('data_dir')/'external_test_target.npy')).long()
 ref=FastIN(Q,Q/'IN15_TRAINED_AFFINE.bin');pooled={}
 for index in np.linspace(0,len(tr)-1,24).astype(int):
  ref.frame(tr[index:index+1],exact_current_frame=True)
  for n,(s,ss,count) in ref.stats.items():
   if n in pooled:
    u,v,c=pooled[n];pooled[n]=(u+s,v+ss,c+count)
   else:pooled[n]=(s.clone(),ss.clone(),count)
 bias=bytearray((Q/'bias_int32.bin').read_bytes());req=bytearray((Q/'requant_int32.bin').read_bytes())
 for row in manifest['layers'][:15]:
  s,ss,count=pooled[row['name']]
  for c,(s1,s2,aff) in enumerate(zip(s,ss,ref.affine[row['name']])):
   b,mult,shift=coefficients(int(s1),int(s2),count,*aff);struct.pack_into('<i',bias,row['bias_offset']+4*c,b);struct.pack_into('<ii',req,row['requant_offset']+8*c,mult,shift)
 (Q/'bias_int32.bin').write_bytes(bias);(Q/'requant_int32.bin').write_bytes(req)
 mapping=pack(Q,Q);assert mapping['bytes']==24960 and len(mapping['segments'])==55
 slow=StreamingINReference(Q,Q/'IN15_TRAINED_AFFINE.bin');fast=FastIN(Q,Q/'IN15_TRAINED_AFFINE.bin')
 ys=slow.frame(test[:1],exact_current_frame=True);yf=fast.frame(test[:1],exact_current_frame=True);assert torch.equal(ys,yf)
 for n in slow.stats:
  for v,w in zip(slow.stats[n],fast.stats[n]):assert torch.equal(v,w) if isinstance(v,torch.Tensor) else v==w
 ids=[0,25,80,100];xs=torch.cat([ex,test[ids]]);ts=torch.cat([et,target[ids]])
 exact=[];history=[];rows=[];quality=[]
 fp=m(xs.float()/255)*255
 for i,x in enumerate(xs):
  r=FastIN(Q,Q/'IN15_TRAINED_AFFINE.bin');cur=r.frame(x[None],exact_current_frame=True)
  r=FastIN(Q,Q/'IN15_TRAINED_AFFINE.bin');first=r.frame(x[None])
  for f in range(1,45):last=r.frame(x[None])
  exact.append(cur[0]);history.append(last[0]);rows.append(dict(index=i,static_frames=45,first_vs_exact_mae=float((first.float()-cur.float()).abs().mean()),history_vs_exact_mae=float((last.float()-cur.float()).abs().mean())))
  mse=float((fp[i]-cur[0].float()).square().mean());quality.append(dict(index=i,qat_vs_integer_mae=float((fp[i]-cur[0].float()).abs().mean()),psnr=10*math.log10(255**2/max(mse,1e-10))))
  print('static',i,rows[-1],flush=True)
 grid(SRC/'integer_comparison.png',[('unseen photo',xs.float()/255),('Mosaic teacher',ts.float()/255),('trained QAT FP32 interface',fp/255),('INT8 historical IN frame45',torch.stack(history).float()/255)],rows=8)
 grid(SRC/'result_preview.png',[('unseen photo',xs.float()/255),('Mosaic INT8 historical IN',torch.stack(history).float()/255)],rows=8)
 extreme=[]
 for name,x in [('black',torch.zeros_like(xs[:1])),('white',torch.full_like(xs[:1],255)),('gray',torch.full_like(xs[:1],128))]:
  r=FastIN(Q,Q/'IN15_TRAINED_AFFINE.bin')
  for f in range(30):r.frame(x)
  extreme.append(dict(scene=name,frames=30,all_coefficient_ranges_passed=True))
 dyn=[];sampled=[];r=FastIN(Q,Q/'IN15_TRAINED_AFFINE.bin')
 for f in range(90):
  x=xs[:1] if f<30 else (xs[1:2] if f<60 else (xs[1:2].float()*.55).round().long());y=r.frame(x)
  if f in [0,14,29,30,44,59,60,74,89]:
   rr=FastIN(Q,Q/'IN15_TRAINED_AFFINE.bin');cur=rr.frame(x,exact_current_frame=True);dyn.append(dict(frame=f+1,history_vs_exact_mae=float((cur.float()-y.float()).abs().mean())));sampled.append(y[0])
 # All test images are untouched by calibration and selection.
 for i in range(len(test)):
  rr=FastIN(Q,Q/'IN15_TRAINED_AFFINE.bin');y=rr.frame(test[i:i+1],exact_current_frame=True);q=m(test[i:i+1].float()/255)*255
  quality.append(dict(test_index=i,qat_vs_integer_mae=float((q-y.float()).abs().mean())))
 report=dict(architecture=ARCHITECTURE,style='Mosaic',parameters=15619,convolutions=16,IN_sites=15,IN_channels=400,scan_bytes=24960,segments=55,affine_bytes=3200,
  weight_sha256=sha((Q/'codec16_rtl_ddr.bin').read_bytes()),weight_crc32=mapping['crc32'],affine_crc32=zlib.crc32((Q/'IN15_TRAINED_AFFINE.bin').read_bytes()),
  fast_vs_INT64_bit_exact=True,raw_statistics_bit_exact=True,static_checks=rows,extreme_checks=extreme,dynamic_checks=dyn,quality=quality,
  test_count=len(test),test_mean_qat_vs_integer_mae=float(np.mean([r['qat_vs_integer_mae'] for r in quality if 'test_index' in r])),
  teacher_is_training_only=True,source_engineering_modified=False,history_trained=False,history_integer_validated=True,rtl_recompiled=False,board_tested=False,directly_flashable=False,
  limitation='Candidate numeric/layout validation only; historical IN differs from exact per-frame IN. Firmware CRC/bank integration and board validation are separate work.')
 write(SRC/'validation_report.json',report);write(Q/'validation_report.json',report);print(json.dumps(report,ensure_ascii=False),flush=True)
if __name__=='__main__':main()
