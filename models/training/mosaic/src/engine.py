from runtime import *
import json,time,random,math,hashlib,inspect,shutil
import torch,numpy as np
from torch import nn
from torch.nn import functional as F
from torchvision.models.vgg import make_layers,cfgs
from PIL import Image,ImageDraw,ImageOps
from model_codec16_in.model import Codec16IN,IN_SITES,ARCHITECTURE,canonicalize_gamma
from model_codec16.quantization import Quantizer
from teacher_model import TransformerNet


def write(p,v):
 p=Path(p);p.with_suffix('.tmp').write_text(json.dumps(v,indent=2,ensure_ascii=False),encoding='utf-8');p.with_suffix('.tmp').replace(p)

def grid(path,columns,rows=6):
 n=min(rows,len(columns[0][1]));out=Image.new('RGB',(256*len(columns),166*n),'white');d=ImageDraw.Draw(out)
 for j,(label,t) in enumerate(columns):
  for i in range(n):
   a=t[i].detach().cpu().clamp(0,1).permute(1,2,0).numpy();out.paste(Image.fromarray((a*255).round().astype('uint8')),(256*j,166*i+22));d.text((256*j+3,166*i+4),label,fill='black')
 out.save(path)

class Features(nn.Module):
 def __init__(self):
  super().__init__();self.net=make_layers(cfgs['D'])[:23]
  raw=torch.load(asset('vgg_weights'),map_location='cpu',weights_only=True)
  self.net.load_state_dict({k.removeprefix('features.'):v for k,v in raw.items() if k.startswith('features.') and int(k.split('.')[1])<23});self.requires_grad_(False)
  self.register_buffer('mean',torch.tensor([.485,.456,.406])[None,:,None,None]);self.register_buffer('std',torch.tensor([.229,.224,.225])[None,:,None,None])
 def forward(self,x):
  x=(x-self.mean)/self.std;out=[]
  for i,m in enumerate(self.net):
   x=m(x)
   if i in [3,8,15,22]:out.append(x)
  return out

def gram(f):
 b,c,h,w=f.shape;v=f.reshape(b,c,-1);return v@v.transpose(1,2)/(c*h*w)
def edges(y):return (y[:,:,:,1:]-y[:,:,:,:-1],y[:,:,1:,:]-y[:,:,:-1,:])

from losses import loss_terms, objective

@torch.inference_mode()
def prepare():
 path=asset('data_dir');path.mkdir(parents=True,exist_ok=True)
 if (path/'prepared.json').exists():validate_data();return
 teacher=TransformerNet().cuda().eval();state=torch.load(asset('teacher_weights'),map_location='cpu',weights_only=True)
 state={k:v for k,v in state.items() if not (k.endswith('running_mean') or k.endswith('running_var'))};teacher.load_state_dict(state,strict=True)
 coco=sorted(asset('coco_dir').glob('*.jpg'))
 assert len(coco)>=1152, 'COCO directory needs at least 1152 jpg files'
 rng=np.random.default_rng(20261031);order=rng.permutation(len(coco));selected={};offset=0
 for split,count in [('train',1024),('val',64),('test',64)]:
  selected[split]=[str(coco[i]) for i in order[offset:offset+count]];offset+=count
 def crop(path):
  with Image.open(path) as im:
   im=ImageOps.exif_transpose(im).convert('RGB');s=max(256/im.width,144/im.height);im=im.resize((max(256,round(im.width*s)),max(144,round(im.height*s))),Image.Resampling.LANCZOS);left=(im.width-256)//2;top=(im.height-144)//2
   return np.array(im.crop((left,top,left+256,top+144))).copy().transpose(2,0,1)
 for split in ['train','val','test','external_test']:
  raw=np.load(asset('base_data_dir')/(split+'.npy'),mmap_mode='r');ids=np.linspace(0,len(raw)-1,1536).round().astype(int) if split=='train' else np.arange(len(raw))
  x=np.asarray(raw[ids]).copy()
  if split in selected:x=np.concatenate([x,np.stack([crop(p) for p in selected[split]])])
  ys=[]
  for start in range(0,len(x),8):
   xx=torch.from_numpy(x[start:start+8]).cuda().float();y=teacher(xx).clamp(0,255).round().byte().cpu().numpy();ys.append(y)
  target=np.concatenate(ys);np.save(path/(split+'_content.npy'),x);np.save(path/(split+'_target.npy'),target)
  print(json.dumps(dict(prepare=split,images=len(x))),flush=True)
  if split=='external_test':grid(ROOT/'teacher_preview.png',[('photo',torch.from_numpy(x).float()/255),('Mosaic teacher',torch.from_numpy(target).float()/255)],rows=4)
 write(path/'prepared.json',dict(train_images=2560,val_images=144,test_images=144,source=str(asset('base_data_dir')),COCO_split_paths=selected,teacher='original PyTorch mosaic.pth, RGB0..255 input',split_note='fixed disjoint image splits; external never trained',training_indices=np.linspace(0,4095,1536).round().astype(int).tolist()))
 del teacher;torch.cuda.empty_cache()

def save(g,out,step,phase,cfg):
 torch.save(dict(architecture=ARCHITECTURE,trained_for_in=True,qat=g.quant_enabled,input_hw=[144,256],in_sites=list(IN_SITES),state_dict={k:v.detach().cpu() for k,v in g.state_dict().items()},step=step,phase=phase,style='Mosaic stained glass',training_config=cfg,board_validated=False),out)

@torch.no_grad()
def evaluate(g,net,vx,vt,out,step,ex,et,strength=1.):
 g.eval();metrics=[]
 for i in range(0,len(vx),4):
  x,t=vx[i:i+4],vt[i:i+4];v=loss_terms(g(x),x,t,net,net(x),net(t));metrics.append({k:float(z) for k,z in v.items()})
 avg={k:float(np.mean([r[k] for r in metrics])) for k in metrics[0]};avg['score']=float(objective(avg,strength));write(out/f'eval_{step:06d}.json',avg)
 ids=torch.tensor([0,25,80,100],device='cuda');xx=torch.cat([ex,vx[ids]]);tt=torch.cat([et,vt[ids]])
 grid(out/f'preview_{step:06d}.png',[('held-out photo',xx),('Mosaic teacher',tt),('Codec16IN student',g(xx))],rows=8)
 g.train();return avg

@torch.no_grad()
def calibrate(g,x):
 g.eval();g.set_quantization(False,True)
 for ids in torch.linspace(0,len(x)-1,64,device='cuda').long().split(4):
  for gain in [.5,1,1.5]:g((x[ids]*gain).clamp(0,1))
 for q in g.modules():
  if isinstance(q,Quantizer) and q.fixed_amax is None:q.amax.fill_(6.)
 g.set_quantization(True,False);g.connect_scales();g.train()

def main(argv=None):
 import argparse
 p=argparse.ArgumentParser();p.add_argument('--steps',type=int,default=2800);p.add_argument('--qat-steps',type=int,default=500);p.add_argument('--run',default='run01');p.add_argument('--init');p.add_argument('--strength',type=float,default=1.);a=p.parse_args(argv)
 if a.steps<1 or a.qat_steps<1:raise ValueError('FP32 and QAT steps must both be positive')
 torch.set_num_threads(4);torch.manual_seed(20261031);np.random.seed(20261031);random.seed(20261031);torch.backends.cudnn.benchmark=True
 torch.backends.cuda.matmul.allow_tf32=False;torch.backends.cudnn.allow_tf32=False
 prepare();out=ROOT/a.run;out.mkdir(parents=True,exist_ok=True)
 if (out/'config.json').exists():raise FileExistsError(f'Run already exists: {out}; choose a new --run name')
 def data(s,k):return torch.from_numpy(np.load(asset('data_dir')/f'{s}_{k}.npy')).cuda().float()/255
 x,t=data('train','content'),data('train','target');vx,vt=data('val','content'),data('val','target');ex,et=data('external_test','content'),data('external_test','target')
 g=Codec16IN();initial=Path(a.init) if a.init else asset('initial_checkpoint');payload=torch.load(initial,map_location='cpu',weights_only=True);g.load_state_dict(payload['state_dict'],strict=True);g=canonicalize_gamma(g).cuda();g.set_quantization(False)
 for n in IN_SITES:
  m=g.get_submodule(n);m.conv.bias.data.zero_();m.conv.bias.requires_grad_(False)
 assert sum(v.numel() for v in g.parameters())==15619 and len(g.layer_contract())==16
 net=Features().cuda().eval();cfg=dict(vars(a),architecture=ARCHITECTURE,parameters=15619,IN_sites=15,IN_channels=400,train_images=len(x),val_images=len(vx),batch=6,initial=str(initial),initial_sha256=hashlib.sha256(initial.read_bytes()).hexdigest(),loss='Mosaic texture v2: multiscale Gram, local patches, palette/chroma, bounded high-frequency energy',hardware_delay_trained=False,source_engineering_modified=False,seed=20261031)
 cfg.update(resolved_config=CONFIG,objective_source=inspect.getsource(objective),loss_terms_source=inspect.getsource(loss_terms),entry_script=str(Path(sys.argv[0]).resolve()))
 source_files=[PACKAGE/'mosaic.py',*sorted((PACKAGE/'src').rglob('*.py'))]
 cfg['source_sha256']={p.relative_to(PACKAGE).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in source_files}
 for source_file in source_files:
  dest=out/'source_snapshot'/source_file.relative_to(PACKAGE);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source_file,dest)
 write(out/'config.json',cfg);r=evaluate(g,net,vx,vt,out,0,ex,et,a.strength);best={'fp32':r['score'],'qat':float('inf')};save(g,out/'best_fp32.pt',0,'initial',cfg)
 opt=torch.optim.Adam(filter(lambda v:v.requires_grad,g.parameters()),lr=3e-4);start=time.time();log=(out/'metrics.jsonl').open('a',encoding='utf-8',buffering=1)
 for step in range(1,a.steps+a.qat_steps+1):
  if step==a.steps+1:
   g.load_state_dict(torch.load(out/'best_fp32.pt',map_location='cuda',weights_only=True)['state_dict']);calibrate(g,x);opt=torch.optim.Adam(filter(lambda v:v.requires_grad,g.parameters()),lr=1.5e-5)
  phase='qat' if step>a.steps else 'fp32'
  if phase=='fp32':
   for group in opt.param_groups:group['lr']=3e-4*(1-.65*(step/a.steps))
  ids=torch.randint(len(x),(6,),device='cuda');xx,tt=x[ids],t[ids]
  if random.random()<.5:xx=xx.flip(-1);tt=tt.flip(-1)
  # Mild input exposure variation; teacher target remains the same recognizable scene.
  xx=(xx*(.85+.3*torch.rand(6,1,1,1,device='cuda'))).clamp(0,1)
  with torch.no_grad():fx=net(xx);ft=net(tt)
  opt.zero_grad(set_to_none=True);v=loss_terms(g(xx),xx,tt,net,fx,ft);loss=objective(v,a.strength)
  if not torch.isfinite(loss):raise FloatingPointError('nonfinite loss')
  loss.backward();torch.nn.utils.clip_grad_norm_(g.parameters(),10);opt.step()
  with torch.no_grad():
   for n in IN_SITES:
    norm=g.get_submodule(n).norm;norm.weight.clamp_(.02,4);norm.bias.clamp_(-4,4)
  if step%50==0:
   msg=dict(step=step,phase=phase,loss=float(loss.detach()),elapsed_s=time.time()-start,**{k:float(z.detach()) for k,z in v.items()});write(out/'status.json',msg);log.write(json.dumps(msg)+'\n');print(json.dumps(msg),flush=True)
  if step%400==0 or step in [200,a.steps,a.steps+a.qat_steps]:
   r=evaluate(g,net,vx,vt,out,step,ex,et,a.strength);save(g,out/'latest.pt',step,phase,cfg)
   if r['score']<best[phase]:best[phase]=r['score'];save(g,out/f'best_{phase}.pt',step,phase,cfg)
   print(json.dumps(dict(evaluation_step=step,metrics=r)),flush=True)
 write(out/'status.json',dict(status='completed',steps=a.steps+a.qat_steps,elapsed_s=time.time()-start,best=best));log.close()
if __name__=='__main__':main()
