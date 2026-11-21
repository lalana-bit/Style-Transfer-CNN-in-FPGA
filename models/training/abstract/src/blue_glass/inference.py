"""CPU integer replay with explicit handling of portrait side padding."""
from pathlib import Path
import numpy as np
from PIL import Image, ImageOps
import torch
from .hardware import FastIN


def infer(cfg, source, output, resize='fit', frames=60, current=False):
    torch.set_num_threads(cfg['export']['cpu_threads'])
    torch.backends.mkldnn.enabled = False
    q = Path(cfg['paths']['run']) / 'candidate'
    with Image.open(source) as raw:
        image = ImageOps.exif_transpose(raw).convert('RGB')
    if resize == 'fit':
        image = ImageOps.fit(image, (256, 144), method=Image.Resampling.LANCZOS)
        pixels = np.array(image)
        box = (0, 0, 256, 144)
    else:
        image = ImageOps.contain(image, (256, 144), method=Image.Resampling.LANCZOS)
        pixels = np.array(image)
        px, py = 256 - image.width, 144 - image.height
        left, top = px // 2, py // 2
        pixels = np.pad(pixels, ((top, py - top), (left, px - left), (0, 0)), mode='edge')
        box = (left, top, left + image.width, top + image.height)
    x = torch.from_numpy(pixels.copy()).permute(2, 0, 1)[None].long()
    reference = FastIN(q, q / 'IN15_TRAINED_AFFINE.bin')
    if frames < 1:
        raise ValueError('frames must be positive')
    with torch.inference_mode():
        if current:
            y = reference.frame(x, exact_current_frame=True)
        else:
            for _ in range(frames): y = reference.frame(x)
    result = Image.fromarray(y[0].byte().permute(1, 2, 0).numpy()).crop(box)
    destination = Path(output)
    destination.parent.mkdir(parents=True, exist_ok=True)
    result.save(destination)
    print('Saved', destination, 'resize:', resize,
        'note:', 'contain padding affects IN statistics; cropping does not repair the model' if resize == 'contain' else 'centre crop to native 16:9')
