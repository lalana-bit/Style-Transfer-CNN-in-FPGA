"""四风格通用的配对微调入口；不声称复原缺失的原始训练过程。"""
from pathlib import Path
import argparse,json,random,sys
import numpy as np
import torch
from torch.nn import functional as F
from PIL import Image

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'models/common'))
from model_codec16_in.model import Codec16IN,ARCHITECTURE,canonicalize_gamma

class Pairs(torch.utils.data.Dataset):
    def __init__(self,content,targets):
        self.items=[(p,Path(targets)/p.name) for p in sorted(Path(content).glob('*.png')) if (Path(targets)/p.name).is_file()]
        if not self.items:raise ValueError('No same-name PNG content/target pairs')
    def __len__(self):return len(self.items)
    def __getitem__(self,index):
        values=[]
        for p in self.items[index]:
            im=Image.open(p).convert('RGB')
            if im.size!=(256,144):raise ValueError(f'{p}: expected 256x144')
            values.append(torch.from_numpy(np.array(im).copy()).permute(2,0,1).float()/255)
        return tuple(values)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--style',choices=('starry','cubist','abstract','mosaic'),required=True)
    p.add_argument('--content',type=Path,required=True);p.add_argument('--targets',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--checkpoint',type=Path);p.add_argument('--steps',type=int,default=1000);p.add_argument('--batch',type=int,default=4)
    p.add_argument('--lr',type=float,default=1e-4);p.add_argument('--device',default='cpu');p.add_argument('--seed',type=int,default=20261102);p.add_argument('--qat',action='store_true')
    a=p.parse_args()
    if a.steps<1 or a.batch<1:raise ValueError('steps/batch must be positive')
    random.seed(a.seed);np.random.seed(a.seed);torch.manual_seed(a.seed);torch.set_num_threads(4)
    checkpoint=a.checkpoint or ROOT/'models'/a.style/'checkpoints'/('FP32.pth' if a.style=='starry' else 'FP32_best.pt')
    payload=torch.load(checkpoint,map_location='cpu',weights_only=False)
    assert payload['architecture']==ARCHITECTURE
    model=Codec16IN();model.load_state_dict(payload['state_dict']);model.set_quantization(False)
    model=model.to(a.device)
    if a.qat:
        from hardware_qat import configure,constrain_affine
        model=canonicalize_gamma(model);configure(model)
    data=Pairs(a.content,a.targets);loader=torch.utils.data.DataLoader(data,batch_size=min(a.batch,len(data)),shuffle=True,num_workers=0)
    opt=torch.optim.Adam(model.parameters(),lr=a.lr);a.output.mkdir(parents=True,exist_ok=True)
    config={k:str(v) if isinstance(v,Path) else v for k,v in vars(a).items()}
    config.update(architecture=ARCHITECTURE,parameters=sum(x.numel() for x in model.parameters()),training_kind='new paired fine-tuning, not reproduction of unavailable original recipe',objective='L1 RGB + 0.25 gradient L1')
    (a.output/'config.json').write_text(json.dumps(config,ensure_ascii=False,indent=2),encoding='utf-8')
    model.train();step=0
    with (a.output/'metrics.jsonl').open('w',encoding='utf-8') as log:
        while step<a.steps:
            for x,t in loader:
                x=x.to(a.device);t=t.to(a.device);y=model(x)
                loss=F.l1_loss(y,t)+.25*(F.l1_loss(y[:,:,:,1:]-y[:,:,:,:-1],t[:,:,:,1:]-t[:,:,:,:-1])+F.l1_loss(y[:,:,1:]-y[:,:,:-1],t[:,:,1:]-t[:,:,:-1]))
                if not torch.isfinite(loss):raise ValueError('nonfinite loss')
                opt.zero_grad(set_to_none=True);loss.backward();torch.nn.utils.clip_grad_norm_(model.parameters(),5);opt.step()
                if a.qat:constrain_affine(model)
                step+=1;log.write(json.dumps({'step':step,'loss':float(loss.detach())})+'\n');log.flush()
                if step>=a.steps:break
    torch.save(dict(architecture=ARCHITECTURE,trained_for_in=True,qat=a.qat,input_hw=[144,256],state_dict=model.cpu().state_dict(),step=step,optimizer=opt.state_dict(),training_config=config),a.output/'latest.pt')
    print('Saved fine-tuned checkpoint:',a.output/'latest.pt','; existing deployment weights unchanged.')

if __name__=='__main__':main()
