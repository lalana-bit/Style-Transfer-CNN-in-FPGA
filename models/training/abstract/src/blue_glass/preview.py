"""Numeric replay figures, using only native 16:9 images during training."""
import numpy as np
from PIL import Image, ImageDraw


def grid(path, columns, rows=8):
    n = min(rows, len(columns[0][1]))
    out = Image.new('RGB', (256 * len(columns), 166 * n), 'white')
    draw = ImageDraw.Draw(out)
    for j, (label, tensors) in enumerate(columns):
        for i in range(n):
            a = tensors[i].detach().cpu().clamp(0, 1).permute(1, 2, 0).numpy()
            out.paste(Image.fromarray((a * 255).round().astype('uint8')), (256 * j, 166 * i + 22))
            draw.text((256 * j + 3, 166 * i + 4), label, fill='black')
    out.save(path)
