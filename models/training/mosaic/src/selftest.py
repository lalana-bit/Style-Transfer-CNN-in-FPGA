"""Exercise real gradients, QAT, packing and integer arithmetic together."""
from pathlib import Path
import json
import math
import numpy as np
import torch
from runtime import ROOT, CONFIG, asset
from engine import Features, loss_terms, objective, calibrate, save, write
from model_codec16_in.model import Codec16IN, canonicalize_gamma, IN_SITES
from model_codec16.packing import pack
from model_codec16_in.streaming_reference import StreamingINReference
from integer_export import FastIN, write_export


def main():
    torch.set_num_threads(4)
    torch.manual_seed(20261031)
    torch.backends.cuda.matmul.allow_tf32=False
    torch.backends.cudnn.allow_tf32=False
    torch.backends.mkldnn.enabled=False
    out=ROOT/'selftest'
    out.mkdir(parents=True,exist_ok=True)
    def load(kind):
        return torch.from_numpy(np.load(asset('data_dir')/f'train_{kind}.npy',mmap_mode='r')[:2].copy()).cuda().float()/255
    x,t=load('content'),load('target')
    model=Codec16IN()
    model.load_state_dict(torch.load(asset('initial_checkpoint'),map_location='cpu',weights_only=True)['state_dict'])
    model=canonicalize_gamma(model).cuda()
    assert sum(p.numel() for p in model.parameters())==15619
    for n in IN_SITES:
        m=model.get_submodule(n);m.conv.bias.data.zero_();m.conv.bias.requires_grad_(False)
    net=Features().cuda().eval()
    report={'parameters':15619,'steps':[],'training_config':CONFIG}
    for phase in ['fp32','qat']:
        if phase=='qat':calibrate(model,x)
        else:model.set_quantization(False)
        opt=torch.optim.Adam(filter(lambda p:p.requires_grad,model.parameters()),lr=1.5e-5)
        with torch.no_grad():fx,ft=net(x),net(t)
        before=model.stem.conv.weight.detach().clone()
        opt.zero_grad(set_to_none=True)
        values=loss_terms(model(x),x,t,net,fx,ft)
        loss=objective(values)
        assert torch.isfinite(loss)
        loss.backward()
        assert all(p.grad is None or torch.isfinite(p.grad).all() for p in model.parameters())
        torch.nn.utils.clip_grad_norm_(model.parameters(),10)
        opt.step()
        with torch.no_grad():
            for n in IN_SITES:
                norm=model.get_submodule(n).norm;norm.weight.clamp_(.02,4);norm.bias.clamp_(-4,4)
        assert not torch.equal(before,model.stem.conv.weight)
        report['steps'].append({'phase':phase,'loss':float(loss.detach()),'finite_gradients':True,'weights_updated':True})
        print(phase,'optimization PASS',flush=True)
    checkpoint=out/'best_qat.pt'
    save(model,checkpoint,2,'selftest',{'qat_steps':1})
    cpu=canonicalize_gamma(model.cpu()).eval()
    candidate=out/'candidate'
    manifest=write_export(cpu,{},candidate,checkpoint)
    mapping=pack(candidate,candidate)
    assert mapping['bytes']==24960 and len(mapping['segments'])==55
    assert (candidate/'IN15_TRAINED_AFFINE.bin').stat().st_size==3200
    sample=(x[:1].cpu()*255).round().long()
    fast=FastIN(candidate,candidate/'IN15_TRAINED_AFFINE.bin')
    slow=StreamingINReference(candidate,candidate/'IN15_TRAINED_AFFINE.bin')
    with torch.inference_mode():
        actual=fast.frame(sample,exact_current_frame=True)
        expected=slow.frame(sample,exact_current_frame=True)
    assert torch.equal(actual,expected)
    for n in slow.stats:
        for a,b in zip(slow.stats[n],fast.stats[n]):
            assert torch.equal(a,b) if isinstance(a,torch.Tensor) else a==b
    report.update(status='PASS',scan_bytes=24960,affine_bytes=3200,segments=55,
                  fast_vs_int64_bit_exact=True,raw_stats_bit_exact=True,
                  note='Two training images used for this isolated smoke test; outputs are not delivery weights.')
    write(out/'report.json',report)
    print(json.dumps({k:v for k,v in report.items() if k!='training_config'},indent=2))
