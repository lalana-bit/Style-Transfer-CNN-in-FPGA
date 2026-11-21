"""One FP32 -> QAT runner, including optimizer/RNG state for exact step resume."""
import copy
import json
import random
import time
from pathlib import Path
import numpy as np
import torch
from model_codec16_in.model import Codec16IN, IN_SITES, ARCHITECTURE, canonicalize_gamma
from model_codec16.quantization import Quantizer
from .config import fingerprint, sha_file, write_json
from .data import paired, tensor_batch
from .losses import Features, GlassLoss
from .preview import grid


def save_atomic(value, path):
    temp = path.with_name(path.name + '.tmp')
    torch.save(value, temp)
    temp.replace(path)


def rng_state():
    np_state = np.random.get_state()
    return dict(torch=torch.get_rng_state(), cuda=torch.cuda.get_rng_state_all() if torch.cuda.is_available() else [],
        python=random.getstate(), numpy=(np_state[0], np_state[1].tolist(), *np_state[2:]))


def restore_rng(state):
    torch.set_rng_state(state['torch'].cpu())
    if state['cuda']:
        torch.cuda.set_rng_state_all([s.cpu() for s in state['cuda']])
    random.setstate(state['python'])
    n = state['numpy']
    np.random.set_state((n[0], np.asarray(n[1], dtype=np.uint32), *n[2:]))


def checkpoint(g, step, cfg, phase):
    return dict(architecture=ARCHITECTURE, trained_for_in=True, qat=g.quant_enabled,
        input_hw=[144, 256], in_sites=list(IN_SITES), state_dict={k: v.detach().cpu() for k, v in g.state_dict().items()},
        step=step, phase=phase, style='Blue leaded glass: art1 output reference', training_config=copy.deepcopy(cfg),
        board_validated=False, history_trained=False)


@torch.no_grad()
def calibrate(g, x, ids, device, count):
    g.eval(); g.set_quantization(False, True)
    selected = ids[np.linspace(0, len(ids) - 1, min(count, len(ids))).round().astype(int)]
    for start in range(0, len(selected), 4):
        batch = tensor_batch(x, selected[start:start + 4], device)
        for gain in (.5, 1., 1.5):
            g((batch * gain).clamp(0, 1))
    for quantizer in g.modules():
        if isinstance(quantizer, Quantizer) and quantizer.fixed_amax is None:
            quantizer.amax.fill_(6.)
    g.set_quantization(True, False); g.connect_scales(); g.train()


@torch.no_grad()
def evaluate(g, criterion, dataset, cfg, step):
    x, ids, t = dataset
    device = cfg['train']['device']; batch = cfg['train']['batch']
    g.eval(); sums = {}; count = 0
    for start in range(0, len(ids), batch):
        xx = tensor_batch(x, ids[start:start + batch], device)
        tt = tensor_batch(t, np.arange(start, min(start + batch, len(ids))), device)
        values = criterion.terms(g(xx), xx, tt, criterion.net(xx))
        for key, value in values.items():
            sums[key] = sums.get(key, 0.) + float(value) * len(xx)
        count += len(xx)
    result = {k: v / count for k, v in sums.items()}
    result['score'] = float(criterion.objective(result))
    sample = tensor_batch(x, ids[:8], device)
    teacher = tensor_batch(t, np.arange(min(8, len(t))), device)
    run = Path(cfg['paths']['run'])
    grid(run / f'preview_{step:06d}.png', [('validation photo', sample), ('Magenta target', teacher), ('Codec16IN', g(sample))])
    write_json(run / f'eval_{step:06d}.json', result)
    g.train()
    return result


def train(cfg, resume=False, stop_after=None):
    args = cfg['train']; run = Path(cfg['paths']['run'])
    device = args['device']
    if device.startswith('cuda') and not torch.cuda.is_available():
        raise RuntimeError('CUDA PyTorch is unavailable; install the trainer requirements or choose device=cpu for a short smoke test')
    torch.set_num_threads(args['cpu_threads'])
    torch.manual_seed(args['seed']); np.random.seed(args['seed']); random.seed(args['seed'])
    torch.backends.cudnn.benchmark = True
    torch.backends.cuda.matmul.allow_tf32 = False; torch.backends.cudnn.allow_tf32 = False
    datasets = {s: paired(cfg, s) for s in ('train', 'val')}
    x, ids, target = datasets['train']
    g = Codec16IN()
    initial = torch.load(cfg['paths']['init'], map_location='cpu', weights_only=True)
    if initial['architecture'] != ARCHITECTURE:
        raise ValueError('Initial checkpoint is incompatible with Codec16IN')
    g.load_state_dict(initial['state_dict'], strict=True)
    g = canonicalize_gamma(g).to(device); g.set_quantization(False)
    for name in IN_SITES:
        bias = g.get_submodule(name).conv.bias
        bias.data.zero_(); bias.requires_grad_(False)
    if sum(p.numel() for p in g.parameters()) != 15619:
        raise ValueError('Network parameter contract changed')
    net = Features(cfg['paths']['vgg']).to(device).eval()
    criterion = GlassLoss(net, cfg['paths']['style'], device, args['seed'])
    criterion.weights = cfg['loss']['weights']; criterion.style_scale = cfg['loss']['style_scale']
    identity = fingerprint({'train': args, 'loss': cfg['loss'], 'teacher': cfg['teacher'],
        'init_sha256': sha_file(cfg['paths']['init']), 'style_sha256': sha_file(cfg['paths']['style']),
        'targets_manifest_sha256': sha_file(Path(cfg['paths']['targets']) / 'manifest.json')})
    first = 0; best = {'fp32': float('inf'), 'qat': float('inf')}
    optimizer = torch.optim.Adam(filter(lambda p: p.requires_grad, g.parameters()), lr=args['lr'])
    if resume:
        state = torch.load(run / 'resume.pt', map_location='cpu', weights_only=True)
        if state['identity'] != identity:
            raise ValueError('Resume configuration, dataset or initialization changed')
        g.load_state_dict(state['model']); g.set_quantization(state['phase'] == 'qat')
        optimizer.load_state_dict(state['optimizer'])
        for values in optimizer.state.values():
            for key, value in values.items():
                if isinstance(value, torch.Tensor): values[key] = value.to(device)
        first = state['step']; best = state['best']; restore_rng(state['rng'])
    else:
        run.mkdir(parents=True, exist_ok=False)
        write_json(run / 'resolved_config.json', cfg)
        metric = evaluate(g, criterion, datasets['val'], cfg, 0)
        best['fp32'] = metric['score']
        save_atomic(checkpoint(g, 0, cfg, 'fp32'), run / 'best_fp32.pt')
    total = args['fp32_steps'] + args['qat_steps']; started = time.time()
    for step in range(first + 1, total + 1):
        if step == args['fp32_steps'] + 1:
            g.load_state_dict(torch.load(run / 'best_fp32.pt', map_location=device, weights_only=True)['state_dict'])
            calibrate(g, x, ids, device, args['calibration_count'])
            optimizer = torch.optim.Adam(filter(lambda p: p.requires_grad, g.parameters()), lr=args['qat_lr'])
        phase = 'fp32' if step <= args['fp32_steps'] else 'qat'
        if phase == 'fp32':
            for group in optimizer.param_groups: group['lr'] = args['lr'] * (1 - .65 * step / args['fp32_steps'])
        positions = torch.randint(len(ids), (args['batch'],)).numpy()
        xx = tensor_batch(x, ids[positions], device); tt = tensor_batch(target, positions, device)
        if random.random() < .5: xx = xx.flip(-1); tt = tt.flip(-1)
        xx = (xx * (.85 + .3 * torch.rand(len(xx), 1, 1, 1, device=device))).clamp(0, 1)
        with torch.no_grad(): fx = net(xx)
        optimizer.zero_grad(set_to_none=True)
        values = criterion.terms(g(xx), xx, tt, fx); loss = criterion.objective(values)
        if not torch.isfinite(loss): raise FloatingPointError(f'Nonfinite loss at {step}')
        loss.backward(); torch.nn.utils.clip_grad_norm_(g.parameters(), 10); optimizer.step()
        with torch.no_grad():
            for name in IN_SITES:
                norm = g.get_submodule(name).norm; norm.weight.clamp_(.02, 4); norm.bias.clamp_(-4, 4)
        if step % args['log_every'] == 0 or step == total:
            message = dict(step=step, phase=phase, loss=float(loss.detach()), elapsed_s=time.time() - started,
                **{k: float(v.detach()) for k, v in values.items()})
            write_json(run / 'status.json', message)
            with (run / 'metrics.jsonl').open('a', encoding='utf-8') as stream: stream.write(json.dumps(message) + '\n')
            print(json.dumps(message), flush=True)
        if step % args['eval_every'] == 0 or step in (args['fp32_steps'], total) or step == stop_after:
            metric = evaluate(g, criterion, datasets['val'], cfg, step)
            if metric['score'] < best[phase]:
                best[phase] = metric['score']; save_atomic(checkpoint(g, step, cfg, phase), run / f'best_{phase}.pt')
            save_atomic(checkpoint(g, step, cfg, phase), run / 'latest.pt')
            save_atomic(dict(model=g.state_dict(), optimizer=optimizer.state_dict(), rng=rng_state(),
                identity=identity, phase=phase, step=step, best=best), run / 'resume.pt')
        if step == stop_after: break
    finished = step >= total if first < total else True
    write_json(run / 'status.json', dict(status='completed' if finished else 'interrupted_for_resume',
        step=step if first < total else first, total_steps=total, best=best, source_engineering_modified=False,
        history_trained=False, board_tested=False))
