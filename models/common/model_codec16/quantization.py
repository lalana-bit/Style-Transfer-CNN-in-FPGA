from __future__ import annotations
import torch
from torch import nn

class Quantizer(nn.Module):
    """All storage uses signed INT8; nonnegative tensors use codes 0..127."""

    def __init__(self, signed: bool=False, fixed_amax: float | None=None):
        super().__init__()
        self.register_buffer('amax', torch.tensor(fixed_amax or 0.0))
        self.signed = signed
        self.fixed_amax = fixed_amax
        self.enabled = False
        self.observing = False

    @property
    def scale(self):
        return self.amax.clamp_min(1e-07) / 127.0

    def forward(self, x):
        if self.observing and self.fixed_amax is None:
            self.amax.copy_(torch.maximum(self.amax, x.detach().abs().amax().float()))
        if not self.enabled:
            return x
        q = (x / self.scale).round().clamp(-127 if self.signed else 0, 127)
        return x + (q * self.scale - x).detach()

class QConv(nn.Conv2d):

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.register_buffer('input_scale', torch.tensor(1.0 / 127))
        self.enabled = True

    @classmethod
    def from_conv(cls, conv):
        m = cls(conv.in_channels, conv.out_channels, conv.kernel_size, stride=conv.stride, padding=conv.padding, dilation=conv.dilation, groups=conv.groups, padding_mode=conv.padding_mode, bias=conv.bias is not None)
        m.weight.data.copy_(conv.weight)
        if conv.bias is not None:
            m.bias.data.copy_(conv.bias)
        return m

    def integer_parameters(self):
        scale = self.weight.detach().abs().flatten(1).amax(1).clamp_min(1e-07) / 127
        qw = (self.weight / scale[:, None, None, None]).round().clamp(-127, 127)
        qb = (self.bias / (scale * self.input_scale)).round() if self.bias is not None else None
        return (qw, qb, scale)

    def forward(self, x):
        if not self.enabled:
            return self._conv_forward(x, self.weight, self.bias)
        qw, qb, scale = self.integer_parameters()
        w = self.weight + (qw * scale[:, None, None, None] - self.weight).detach()
        b = self.bias
        if b is not None:
            b = b + (qb * scale * self.input_scale - b).detach()
        return self._conv_forward(x, w, b)
