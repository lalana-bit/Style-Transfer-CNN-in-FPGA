"""Train the archive's unchanged Codec16IN with RGB 256x144 content/targets."""
import argparse,json,time,random,sys,math,os,subprocess
from pathlib import Path
import numpy as np
from PIL import Image,ImageOps,ImageDraw
import torch
from torch import nn
from torch.nn import functional as F
ROOT=Path(__file__).resolve().parent; BASE=ROOT.parents[2]
sys.path.insert(0,str(BASE/'models/common'))
from model_codec16_in.model import Codec16IN,save_checkpoint,ARCHITECTURE
from torchvision.models import squeezenet1_1

def load_image(p):
 im=Image.open(p).convert('RGB')
 if im.size!=(256,144):raise ValueError(f'Expected physical 256x144 image: {p}, {im.size}')
 return torch.from_numpy(np.asarray(im).copy()).permute(2,0,1).float()/255

class Pairs(torch.utils.data.Dataset):
 def __init__(self,split,target_dir=None):
  self.target_dir=Path(target_dir) if target_dir else BASE/'data/cubist/targets'
  self.paths=sorted(p for p in (BASE/'data/content'/split).glob('*.png') if (self.target_dir/split/p.name).exists())
 def __len__(self):return len(self.paths)
 def __getitem__(self,i):
  p=self.paths[i];return load_image(p),load_image(self.target_dir/p.parent.name/p.name)

class Perceptual(nn.Module):
 def __init__(self,device):
  super().__init__();m=squeezenet1_1(weights=None);m.load_state_dict(torch.load(BASE/'data/perceptual/squeezenet1_1-b8a52dc0.pth',map_location='cpu',weights_only=True));self.net=m.features[:10].to(device).eval().requires_grad_(False)
  self.register_buffer('mean',torch.tensor([.485,.456,.406],device=device)[None,:,None,None]);self.register_buffer('std',torch.tensor([.229,.224,.225],device=device)[None,:,None,None])
 def forward(self,x):
  x=(x-self.mean)/self.std;out=[]
  for i,l in enumerate(self.net):
   x=l(x)
   if i in [3,6,9]:out.append(x)
  return out
def gram(x):
 b,c,h,w=x.shape;a=x.flatten(2);return a@a.transpose(1,2)/(c*h*w)
def color(x):
 r,g,b=x.unbind(1);return torch.stack([.299*r+.587*g+.114*b,(r-g)/2,(r+g-2*b)/4],1)
def swd(x,y,dirs):
 x=color(x).flatten(2);y=color(y).flatten(2)
 # Same fixed 512 uniformly spaced sample sites: deterministic validation.
 idx=torch.linspace(0,x.shape[-1]-1,512,device=x.device).long()
 xp=torch.einsum('kc,bcn->bkn',dirs,x[:,:,idx]).sort(-1).values
 yp=torch.einsum('kc,bcn->bkn',dirs,y[:,:,idx]).sort(-1).values
 return F.l1_loss(xp,yp)
def gradients(x):return (x[:,:,:,1:]-x[:,:,:,:-1],x[:,:,1:,:]-x[:,:,:-1,:])
def patch_desc(x,k=7):
 g=(x*torch.tensor([.299,.587,.114],device=x.device)[None,:,None,None]).sum(1,keepdim=True)
 p=F.unfold(g,kernel_size=k,stride=3).transpose(1,2);p=p-p.mean(-1,keepdim=True)
 return p,F.normalize(p,dim=-1,eps=1e-4)

def preview(model,dataset,device,path,count=6):
 model.eval();canvas=Image.new('RGB',(256*3,164*min(count,len(dataset))),'#181818');d=ImageDraw.Draw(canvas)
 with torch.no_grad():
  for i in range(min(count,len(dataset))):
   x,t=dataset[i];y=model(x[None].to(device))[0].cpu()
   for j,z in enumerate([x,t,y]):
    im=Image.fromarray((z.clamp(0,1).permute(1,2,0).numpy()*255).round().astype('uint8'));canvas.paste(im,(j*256,i*164+20))
    d.text((j*256+6,i*164+3),['content 256x144','cubist teacher','IN15 student'][j],fill='white')
 canvas.save(path);model.train()

def main():
 a=argparse.ArgumentParser();a.add_argument('--steps',type=int,default=20000);a.add_argument('--batch',type=int,default=12);a.add_argument('--device',default='cuda');a.add_argument('--resume');a.add_argument('--run',default=str(BASE/'build/training/cubist_original'));args=a.parse_args()
 torch.set_num_threads(6);random.seed(20261031);np.random.seed(20261031);torch.manual_seed(20261031)
 if args.device=='cuda' and not torch.cuda.is_available():raise RuntimeError('CUDA is not available; refusing to silently train on CPU')
 device=torch.device(args.device);torch.backends.cudnn.benchmark=True
 train=Pairs('train');val=Pairs('val')
 if len(train)<100 or len(val)<5:raise RuntimeError(f'Insufficient paired data: {len(train)} train, {len(val)} val')
 run=ROOT/args.run;run.mkdir(parents=True,exist_ok=True)
 model=Codec16IN().to(device)
 # Initialization keeps the archive output clamp in its active gradient range.
 with torch.no_grad():model.out.weight.mul_(.1);model.out.bias.fill_(.5)
 opt=torch.optim.Adam(model.parameters(),lr=2e-4);start=0;norm={};best=float('inf')
 if args.resume:
  p=torch.load(args.resume,map_location=device,weights_only=False);model.load_state_dict(p['state_dict']);opt.load_state_dict(p['optimizer']);start=p['step'];norm=p['loss_scales'];best=p.get('best_val',best)
 feat=Perceptual(device);dirs=F.normalize(torch.randn(24,3,device=device),dim=1)
 source=Image.open(BASE/'data/styles/cubist.jpg').convert('RGB');source=ImageOps.fit(source,(256,144),Image.Resampling.LANCZOS)
 style=torch.from_numpy(np.array(source).copy()).permute(2,0,1).float()[None].to(device)/255
 with torch.no_grad():_,bank=patch_desc(style);bank=bank[:,::2].transpose(1,2)
 metadata={'architecture':ARCHITECTURE,'input_hw':[144,256],'physical_image_size':[256,144],'train_pairs':len(train),'val_pairs':len(val),'device':str(device),'gpu':torch.cuda.get_device_name() if device.type=='cuda' else None,'losses':'paired low-pass RGB and gradients; pretrained SqueezeNet feature distillation/Gram; joint opponent-color SWD; local normalized luminance patch matching; weak TV','note':'FP32 training. Not hardware IN calibration, not QAT, not a deployable flash image.','parameters':sum(p.numel() for p in model.parameters())}
 (run/'config.json').write_text(json.dumps(metadata,indent=2),encoding='utf8');print(json.dumps(metadata),flush=True)
 loader=torch.utils.data.DataLoader(train,batch_size=args.batch,shuffle=True,num_workers=0,drop_last=True);it=iter(loader);t0=time.time();log=(run/'metrics.jsonl').open('a',encoding='utf8')
 model.train()
 for step in range(start+1,args.steps+1):
  try:x,t=next(it)
  except StopIteration:
   # Include newly completed teacher pairs only at epoch boundaries.
   expanded=Pairs('train')
   if len(expanded)>len(train):
    train=expanded;loader=torch.utils.data.DataLoader(train,batch_size=args.batch,shuffle=True,num_workers=0,drop_last=True)
   it=iter(loader);x,t=next(it)
  x=x.to(device);t=t.to(device);y=model(x);fy=feat(y)
  with torch.no_grad():ft=feat(t);fx=feat(x)
  yg=gradients(y);tg=gradients(t);_,pd=patch_desc(y);sim=torch.bmm(pd,bank.expand(y.shape[0],-1,-1));patch=(1-sim.amax(-1)).mean()
  losses={'paired':F.l1_loss(F.avg_pool2d(y,3,1,1),F.avg_pool2d(t,3,1,1)),
   'features':sum(F.l1_loss(u,v) for u,v in zip(fy,ft)),
   'gram':sum(F.l1_loss(gram(u),gram(v)) for u,v in zip(fy,ft)),
   'color':swd(y,t,dirs)+.10*swd(y,style.expand(y.shape[0],-1,-1,-1),dirs),
   'patch':patch,'edge':sum(F.l1_loss(u,v) for u,v in zip(yg,tg)),
   'content':F.l1_loss(fy[-1],fx[-1]),'tv':sum(u.abs().mean() for u in yg)}
  if step<=30:
   for k,v in losses.items():norm[k]=max(float(v.detach()),1e-5) if k not in norm else .9*norm[k]+.1*max(float(v.detach()),1e-5)
  ramp=min(1.,max(.1,step/1000));weights={'paired':2.,'features':2.,'gram':3.*ramp,'color':3.,'patch':1.5*ramp,'edge':.5,'content':.15,'tv':.015}
  total=sum(v/norm[k]*weights[k] for k,v in losses.items());opt.zero_grad(set_to_none=True);total.backward();gn=float(torch.nn.utils.clip_grad_norm_(model.parameters(),5.));opt.step()
  lr=2e-4*(.05+.95*(1+math.cos(math.pi*step/args.steps))/2)
  for g in opt.param_groups:g['lr']=lr
  if step%25==0 or step==1:
   row={'step':step,'loss':float(total.detach()),'losses':{k:float(v.detach()) for k,v in losses.items()},'lr':lr,'grad_norm':gn,'seconds':round(time.time()-t0,2),'train_pairs':len(train)};log.write(json.dumps(row)+'\n');log.flush();print(json.dumps(row),flush=True)
   (run/'status.json').write_text(json.dumps({'state':'training',**row}),encoding='utf8')
  if step%250==0 or step==args.steps:
   model.eval();vals=[]
   with torch.no_grad():
    for i in range(min(32,len(val))):
     vx,vt=val[i];vy=model(vx[None].to(device));vt=vt[None].to(device)
     vf=feat(vy);tf=feat(vt);vv={'paired':F.l1_loss(F.avg_pool2d(vy,3,1,1),F.avg_pool2d(vt,3,1,1)),'features':sum(F.l1_loss(u,v) for u,v in zip(vf,tf)),'gram':sum(F.l1_loss(gram(u),gram(v)) for u,v in zip(vf,tf)),'color':swd(vy,vt,dirs)}
     # Fixed validation weights: comparable across texture warm-up stages.
     vals.append(sum(float(v)/norm[k]*{'paired':2,'features':2,'gram':3,'color':3}[k] for k,v in vv.items()))
   score=sum(vals)/len(vals);newbest=score<best;best=min(best,score)
   payload={'architecture':ARCHITECTURE,'trained_for_in':True,'qat':False,'input_hw':[144,256],'state_dict':model.state_dict(),'optimizer':opt.state_dict(),'step':step,'loss_scales':norm,'best_val':best,'validation_score':score,'deployable':False}
   torch.save(payload,run/'latest.pt')
   if newbest:torch.save(payload,run/'best.pt')
   preview(model,val,device,run/'latest_preview.png');print('VALIDATION',step,score,'best',best,flush=True)
   model.train()
 (run/'status.json').write_text(json.dumps({'state':'completed_fp32','steps':args.steps,'best_val':best,'deployable':False}),encoding='utf8');log.close()
if __name__=='__main__':main()
