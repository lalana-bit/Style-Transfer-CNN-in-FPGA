import torch
import numpy as np
from torch import nn
from torch.nn import functional as F
from PIL import Image

def make_layers(config):
    layers = []
    ci = 3
    for c in config:
        if c == 'M':
            layers.append(nn.MaxPool2d(2, 2))
        else:
            layers.extend([nn.Conv2d(ci, c, 3, padding=1), nn.ReLU(inplace=True)])
            ci = c
    return nn.Sequential(*layers)

class Features(nn.Module):

    def __init__(self, checkpoint):
        super().__init__()
        self.net = make_layers([64, 64, 'M', 128, 128, 'M', 256, 256, 256, 'M', 512, 512, 512, 'M', 512, 512, 512, 'M'])[:23]
        raw = torch.load(checkpoint, map_location='cpu', weights_only=True)
        self.net.load_state_dict({k.removeprefix('features.'): v for k, v in raw.items() if k.startswith('features.') and int(k.split('.')[1]) < 23})
        self.requires_grad_(False)
        self.register_buffer('mean', torch.tensor([0.485, 0.456, 0.406])[None, :, None, None])
        self.register_buffer('std', torch.tensor([0.229, 0.224, 0.225])[None, :, None, None])

    def forward(self, x):
        x = (x - self.mean) / self.std
        out = []
        for i, m in enumerate(self.net):
            x = m(x)
            if i in [3, 8, 15, 22]:
                out.append(x)
        return out

def gram(f):
    b, c, h, w = f.shape
    v = f.reshape(b, c, -1)
    return v @ v.transpose(1, 2) / (c * h * w)

def blur(x, k=3):
    return F.avg_pool2d(F.pad(x, (k // 2,) * 4, mode='replicate'), k, 1)

def gray(x):
    return (x * x.new_tensor([0.299, 0.587, 0.114])[None, :, None, None]).sum(1, keepdim=True)

def zscore(x):
    return (x - x.mean((2, 3), keepdim=True)) / x.std((2, 3), keepdim=True).clamp_min(0.03)

def patches(f, n=256):
    p = F.unfold(f, 3, stride=2).transpose(1, 2)
    ids = torch.linspace(0, p.shape[1] - 1, min(n, p.shape[1]), device=p.device).long()
    p = p[:, ids]
    return F.normalize(p - p.mean(-1, keepdim=True), dim=-1, eps=1e-06)

class ReferenceStyleLoss(nn.Module):

    def __init__(self, net, style_path, device, seed):
        content_weight = 0.8
        clean_weight = 1.0
        super().__init__()
        self.net = net
        self.content_weight = content_weight
        self.clean_weight = clean_weight
        im = Image.open(style_path).convert('RGB')
        a = np.array(im.resize((230, 288), Image.Resampling.LANCZOS)).copy()
        s = torch.from_numpy(a).permute(2, 0, 1)[None].to(device).float() / 255
        with torch.no_grad():
            fs = net(s)
            self.targets = [gram(f).detach() for f in fs]
            self.coarse = [gram(f).detach() for f in net(F.avg_pool2d(s, 2))]
            self.bank = patches(fs[1], 1000).detach()
            self.palette = s.flatten(2).transpose(1, 2)[:, torch.linspace(0, s.shape[2] * s.shape[3] - 1, 1536, device=device).long()]
            rng = torch.Generator(device=device).manual_seed(seed)
            self.directions = F.normalize(torch.randn(3, 24, generator=rng, device=device), dim=0)
            self.color_sorted = (self.palette @ self.directions).sort(1).values
            self.hf_target = float((s - blur(s)).square().mean())
            self.mean = s.mean((2, 3))
            self.std = s.std((2, 3))

    def forward(self, y, x, fx):
        fy = self.net(y)
        fc = self.net(F.avg_pool2d(y, 2))
        weights = [0.35, 0.8, 1.0, 1.0]
        sty = sum((w * F.mse_loss(gram(f), g.expand(len(y), -1, -1)) / g.square().mean().clamp_min(1e-08) for w, f, g in zip(weights, fy, self.targets))) / sum(weights)
        coarse = sum((F.mse_loss(gram(f), g.expand(len(y), -1, -1)) / g.square().mean().clamp_min(1e-08) for f, g in zip(fc, self.coarse))) / 4
        p = patches(fy[1])
        patch = (1 - (p @ self.bank.transpose(1, 2)).max(-1).values).mean()
        content = sum((F.mse_loss(fy[i], fx[i]) / fx[i].square().mean().clamp_min(1e-05) for i in [2, 3])) / 2
        gy, gx = (gray(y), gray(x))
        layout = F.l1_loss(zscore(F.avg_pool2d(gy, 8)), zscore(F.avg_pool2d(gx, 8)))
        ey, ex = (zscore(F.avg_pool2d(gy, 4)), zscore(F.avg_pool2d(gx, 4)))
        dx = ex[:, :, :, 1:] - ex[:, :, :, :-1]
        dy = ey[:, :, :, 1:] - ey[:, :, :, :-1]
        dx2 = ex[:, :, 1:, :] - ex[:, :, :-1, :]
        dy2 = ey[:, :, 1:, :] - ey[:, :, :-1, :]
        outline = F.relu(dx.abs() * 0.65 - dy * dx.sign()).mean() + F.relu(dx2.abs() * 0.65 - dy2 * dx2.sign()).mean()
        pixels = y.flatten(2).transpose(1, 2)[:, torch.linspace(0, y.shape[2] * y.shape[3] - 1, 1536, device=y.device).long()]
        palette = F.mse_loss((pixels @ self.directions).sort(1).values, self.color_sorted.expand(len(y), -1, -1))
        palette = palette + F.mse_loss(y.mean((2, 3)), self.mean.expand(len(y), -1))
        hf = (y - blur(y)).square().mean()
        excess = F.relu(hf - self.hf_target * 0.85)
        dx = y[:, :, :, 1:] - y[:, :, :, :-1]
        dy = y[:, :, 1:, :] - y[:, :, :-1, :]
        tv = dx.abs().mean() + dy.abs().mean()
        phase = torch.stack([y[:, :, a::2, b::2].mean((2, 3)) for a in range(2) for b in range(2)])
        checker = phase.var(0, unbiased=False).mean()
        return dict(gram=sty, coarse=coarse, patch=patch, content=content, layout=layout, outline=outline, palette=palette, hf_excess=excess, tv=tv, checker=checker)

    def objective(self, v):
        return 4 * v['gram'] + 2 * v['coarse'] + 2 * v['patch'] + self.content_weight * v['content'] + 0.25 * v['layout'] + 0.35 * v['outline'] + 22 * v['palette'] + self.clean_weight * (70 * v['hf_excess'] + 0.2 * v['tv'] + 40 * v['checker'])

class GlassLoss(ReferenceStyleLoss):

    def terms(self, y, x, t, fx):
        v = super().forward(y, x, fx)
        with torch.no_grad():
            ft = self.net(t)
        fy = self.net(y)
        v['teacher_perceptual'] = sum((F.mse_loss(a, b) / b.square().mean().clamp_min(1e-05) for a, b in zip(fy[1:3], ft[1:3]))) / 2
        v['pixel'] = F.l1_loss(y, t)
        v['coarse_pixel'] = F.l1_loss(F.avg_pool2d(y, 4), F.avg_pool2d(t, 4))
        ey = [(y[:, :, :, 1:] - y[:, :, :, :-1]).abs(), (y[:, :, 1:, :] - y[:, :, :-1, :]).abs()]
        et = [(t[:, :, :, 1:] - t[:, :, :, :-1]).abs(), (t[:, :, 1:, :] - t[:, :, :-1, :]).abs()]
        v['texture_energy'] = sum((F.l1_loss(F.avg_pool2d(a, 7, 1), F.avg_pool2d(b, 7, 1)) for a, b in zip(ey, et)))
        hy = (y - blur(y)).square().mean((1, 2, 3))
        ht = (t - blur(t)).square().mean((1, 2, 3))
        v['hf_excess'] = F.relu(hy - ht * 1.05).mean()
        return v

    def objective(self, v):
        return sum((weight * v[name] * (self.style_scale if name in ['gram', 'coarse', 'patch'] else 1.0) for name, weight in self.weights.items()))
