"""Run current-frame or historical IN inference from the packaged integer weights."""
from pathlib import Path
import argparse

import numpy as np
from PIL import Image, ImageOps
import torch

from .integer_in15 import IntegerIN15


def main(package: Path) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-dir', type=Path, default=package / 'model')
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--stream-warmup', action='store_true')
    parser.add_argument('--frames', type=int, default=60)
    parser.add_argument('--schedule', choices=('groups','serial'), default='groups')
    args = parser.parse_args()
    if args.frames < 1:
        raise ValueError('frames must be positive')
    torch.set_num_threads(4)
    torch.backends.mkldnn.enabled = False
    with Image.open(args.input) as image:
        image = ImageOps.fit(ImageOps.exif_transpose(image).convert('RGB'), (256,144), method=Image.Resampling.LANCZOS)
        x = torch.from_numpy(np.array(image)).permute(2,0,1)[None].long()
    reference = IntegerIN15(args.model_dir, args.schedule)
    with torch.inference_mode():
        for _ in range(args.frames if args.stream_warmup else 1):
            result = reference(x, exact=not args.stream_warmup)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    Image.fromarray(result[0].byte().permute(1,2,0).numpy()).save(args.output)
    print(args.output)
