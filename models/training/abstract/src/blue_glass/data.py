"""Fixed uint8 RGB NCHW datasets, with checked content/target alignment."""
import hashlib
import json
from pathlib import Path
import numpy as np
from PIL import Image, ImageOps
from .config import sha_file, write_json

SPLITS = ('train', 'val', 'test', 'external_test')


def content(cfg, split):
    value = np.load(Path(cfg['paths']['content']) / f'{split}_content.npy', mmap_mode='r')
    if value.dtype != np.uint8 or value.ndim != 4 or value.shape[1:] != (3, 144, 256) or not len(value):
        raise ValueError(f'{split}: expected nonempty uint8 [N,3,144,256]')
    return value


def selected_indices(cfg, split, count):
    limit = cfg['teacher'].get('train_count') if split == 'train' else cfg['teacher'].get('eval_count')
    if limit is None:
        return np.arange(count)
    if limit < 1 or limit > count:
        raise ValueError(f'{split}: requested {limit} images from {count}')
    return np.linspace(0, count - 1, limit).round().astype(int)


def source_signature(cfg):
    """Hashes include actual arrays: moving a dataset cannot silently reuse targets."""
    return {s: sha_file(Path(cfg['paths']['content']) / f'{s}_content.npy') for s in SPLITS}


def paired(cfg, split):
    directory = Path(cfg['paths']['targets'])
    manifest = json.loads((directory / 'manifest.json').read_text(encoding='utf-8'))
    if not manifest['completed']:
        raise ValueError('Target generation is incomplete')
    if manifest['teacher'] != cfg['teacher'] or manifest['style_sha256'] != sha_file(cfg['paths']['style']):
        raise ValueError('Target cache belongs to another style or teacher configuration')
    source_path = Path(cfg['paths']['content']) / f'{split}_content.npy'
    if manifest['content_sha256'][split] != sha_file(source_path):
        raise ValueError(f'{split}: source content changed since target generation')
    indices = np.asarray(manifest['indices'][split], dtype=int)
    x = content(cfg, split)
    y = np.load(directory / f'{split}_target.npy', mmap_mode='r')
    if y.dtype != np.uint8 or y.shape != (len(indices), 3, 144, 256):
        raise ValueError(f'{split}: invalid teacher target dimensions')
    if sha_file(directory / f'{split}_target.npy') != manifest['target_sha256'][split]:
        raise ValueError(f'{split}: cached target checksum mismatch')
    if len(np.unique(indices)) != len(indices) or min(indices) < 0 or max(indices) >= len(x):
        raise ValueError(f'{split}: invalid target/source indices')
    return x, indices, y


def tensor_batch(array, indices, device):
    import torch
    return torch.from_numpy(np.array(array[indices], copy=True)).to(device).float() / 255


def audit(cfg):
    hashes = {}
    shapes = {}
    for split in SPLITS:
        array = content(cfg, split)
        shapes[split] = list(array.shape)
        hashes[split] = {hashlib.sha256(x.tobytes()).hexdigest() for x in array}
    overlap = {f'{a}__{b}': len(hashes[a] & hashes[b]) for i, a in enumerate(SPLITS) for b in SPLITS[i + 1:]}
    if any(overlap.values()):
        raise ValueError(f'Exact image overlap between splits: {overlap}')
    return {'shapes': shapes, 'exact_image_overlap': overlap, 'content_sha256': source_signature(cfg)}


def prepare_images(cfg, folder, destination):
    """Create a disjoint 80/10/10 split; no artificial edge-replication padding."""
    paths = sorted(p for p in Path(folder).rglob('*') if p.suffix.lower() in ('.jpg', '.jpeg', '.png', '.webp'))
    images, seen, sources = [], set(), []
    for path in paths:
        with Image.open(path) as im:
            im = ImageOps.fit(ImageOps.exif_transpose(im).convert('RGB'), (256, 144), method=Image.Resampling.LANCZOS)
            a = np.array(im).transpose(2, 0, 1).copy()
        digest = hashlib.sha256(a.tobytes()).hexdigest()
        if digest not in seen:
            seen.add(digest); images.append(a); sources.append(str(path.resolve()))
    if len(images) < 20:
        raise ValueError('At least 20 unique images required; more are needed for useful training')
    dest = Path(destination)
    dest.mkdir(parents=True, exist_ok=False)
    order = np.random.default_rng(cfg['train']['seed']).permutation(len(images))
    n = len(order); a, b, c = int(n * .8), int(n * .9), n - 1
    groups = {'train': order[:a], 'val': order[a:b], 'test': order[b:c], 'external_test': order[c:]}
    for split, ids in groups.items():
        np.save(dest / f'{split}_content.npy', np.stack([images[i] for i in ids]))
    write_json(dest / 'sources.json', {s: [sources[i] for i in ids] for s, ids in groups.items()})
