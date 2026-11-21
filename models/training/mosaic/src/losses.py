"""Texture refinement: coherent style patches and controlled fine-line energy."""
from runtime import asset, CONFIG
from engine import gram as gram_matrix, edges
import torch
from torch.nn import functional as F
from PIL import Image
import numpy as np

def blur(x,k=3):return F.avg_pool2d(F.pad(x,(k//2,)*4,mode='replicate'),k,1)

def patches(f,count):
 p=F.unfold(f,3,stride=2).transpose(1,2)
 ids=torch.linspace(0,p.shape[1]-1,count,device=p.device).long()
 p=p[:,ids];return F.normalize(p-p.mean(-1,keepdim=True),dim=-1,eps=1e-6)

def loss_terms(y,x,t,net,fx,ft):
 if not hasattr(net,'mosaic_targets'):
  im=Image.open(asset('style_image')).convert('RGB')
  a=np.array(im.resize((256,213),Image.Resampling.LANCZOS)).copy()
  with torch.no_grad():
   f=net(torch.from_numpy(a).permute(2,0,1)[None].to(y.device).float()/255)
   net.mosaic_targets=[gram_matrix(z).detach() for z in f]
   net.patch_bank=patches(f[1],768).detach()
 fy=net(y);coarse_features=net(F.avg_pool2d(y,2))
 weights=[.15,.65,1.,1.]
 gram=sum(w*F.mse_loss(gram_matrix(f),z.expand(len(y),-1,-1))/z.square().mean().clamp_min(1e-8) for w,f,z in zip(weights,fy,net.mosaic_targets))/sum(weights)
 coarse=sum(F.mse_loss(gram_matrix(f),z.expand(len(y),-1,-1))/z.square().mean().clamp_min(1e-8) for f,z in zip(coarse_features,net.mosaic_targets))/4
 p=patches(fy[1],256);matches=p@net.patch_bank.transpose(1,2)
 patch=(1-matches.max(-1).values).mean()
 content=sum(F.mse_loss(fy[i],fx[i])/fx[i].square().mean().clamp_min(1e-5) for i in [1,2])/2
 palette=F.mse_loss(y.mean((2,3)),t.mean((2,3)))+F.mse_loss(y.std((2,3)),t.std((2,3)))
 yc=y-y.mean(1,keepdim=True);tc=t-t.mean(1,keepdim=True)
 chroma=F.mse_loss(yc,tc)+4*(yc.square().mean()-tc.square().mean()).abs()
 # Penalize excess tiny-line energy, rather than suppressing all texture.
 # Teacher provides the natural stained-glass texture energy budget per scene.
 hf=(y-blur(y)).square().mean((1,2,3));ht=(t-blur(t)).square().mean((1,2,3))
 excess=F.relu(hf-.9*ht).mean()
 # Alternating pixel patterns are the clearest fine-grid artifact of the
 # preceding run. Strong, broad glass boundaries survive this residual loss.
 alias=(y-blur(y,5)).square().mean((1,2,3));at=(t-blur(t,5)).square().mean((1,2,3))
 alias_excess=F.relu(alias-1.05*at).mean()
 ey,et=edges(y),edges(t)
 texture=sum(F.l1_loss(F.avg_pool2d(a.abs(),7,1),F.avg_pool2d(b.abs(),7,1)) for a,b in zip(ey,et))
 tv=sum(a.abs().mean() for a in ey)
 layout=F.l1_loss(F.avg_pool2d(y.mean(1,keepdim=True),8),F.avg_pool2d(x.mean(1,keepdim=True),8))
 return dict(content=content,gram=gram,coarse_gram=coarse,patch=patch,palette=palette,chroma=chroma,hf_excess=excess,alias_excess=alias_excess,texture=texture,tv=tv,layout=layout)

def objective(v, strength=1.):
 weights = CONFIG['loss_weights']
 return sum(weights[k] * (strength if k == 'gram' else 1.) * v[k] for k in weights)
