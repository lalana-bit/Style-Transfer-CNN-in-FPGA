"""Portable integer inference for the latest two-standard-residual up-first graph."""
from pathlib import Path
import hashlib
import json
import zlib

import torch
from torch.nn import functional as F

from .integer_reference import rounded_shift
from .streaming_reference import StreamingINReference


def verify_packed(directory):
    directory = Path(directory)
    layout = json.loads((directory/'rtl_address_map.json').read_text(encoding='utf8'))
    manifest = json.loads((directory/'quantization_manifest.json').read_text(encoding='utf8'))
    raw = (directory/'codec16_rtl_ddr.bin').read_bytes()
    expected = 'stem8_enc16_32_stdres2_sep3_upfirst32_16_8_3_v1'
    assert manifest['architecture'] == layout['architecture'] == expected
    assert len(raw) == 63296 and len(layout['segments']) == 55
    assert zlib.crc32(raw) == layout['crc32']
    assert hashlib.sha256(raw).hexdigest() == layout['sha256']
    assert len((directory/'IN15_TRAINED_AFFINE.bin').read_bytes()) == 3200
    return layout


class IntegerIN15(StreamingINReference):
    def __init__(self, directory, schedule='groups'):
        directory = Path(directory)
        verify_packed(directory)
        super().__init__(directory, directory/'IN15_TRAINED_AFFINE.bin')
        self.schedule = schedule
        self.group_phase = 0

    def conv(self, name, x):
        row, w, b, q = self.layers[name]
        ph, pw = row['padding']
        acc = F.conv2d(F.pad(x.float(), (pw,pw,ph,ph), mode='replicate'), w.float(),
                       stride=row['stride'], groups=row['groups']).long()[0]
        height, width = acc.shape[-2:]
        acc = acc.reshape(acc.shape[0], -1)
        if name != 'out':
            a = acc >> 8
            self.stats[name] = (a.sum(1), a.square().sum(1), a.shape[1])
            if self.exact:
                self._update(name, self.stats[name])
                row, w, b, q = self.layers[name]
        y = rounded_shift((acc+b[:,None])*q[:,0,None], q[:,1,None])
        quant = self.quantizers[row['output_quantizer']]
        upper = 127
        if name != 'out' and '.pw.' not in name and '.conv2.' not in name:
            upper = min(127,self.relu6_limits[row['output_quantizer']])
        return y.clamp(quant['qmin'],upper).reshape(1,w.shape[0],height,width)

    def __call__(self, u8, *, exact=True, update=True):
        if tuple(u8.shape) != (1,3,144,256):
            raise ValueError('Expected one RGB frame [1,3,144,256]')
        if not exact and self.schedule == 'groups':
            result = super().frame(u8, update=False)
            if update:
                for group in range(3):
                    name = self.order[group*5+self.group_phase]
                    self._update(name,self.stats[name])
                self.group_phase = (self.group_phase+1)%5
            return result
        return super().frame(u8, update=update, exact_current_frame=exact)
