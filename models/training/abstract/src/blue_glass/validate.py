"""Numeric checks plus explicit diagnostics for flat backgrounds and stripes."""
import json
import zlib
from pathlib import Path
import numpy as np
import torch
from model_codec16_in.model import load_checkpoint, canonicalize_gamma
from model_codec16_in.streaming_reference import StreamingINReference
from .config import sha_file, write_json
from .data import content
from .export import compare_target_abi
from .hardware import FastIN
from .preview import grid


@torch.inference_mode()
def validate(cfg, checkpoint=None):
    run = Path(cfg['paths']['run']); q = run / 'candidate'; affine = q / 'IN15_TRAINED_AFFINE.bin'
    torch.set_num_threads(cfg['export']['cpu_threads']); torch.backends.mkldnn.enabled = False
    model, _ = load_checkpoint(checkpoint or run / 'best_qat.pt'); model = canonicalize_gamma(model).eval()
    test = content(cfg, 'test')
    count = min(cfg['export']['test_count'], len(test))
    x = torch.from_numpy(np.array(test[:1], copy=True)).long()
    slow = StreamingINReference(q, affine); fast = FastIN(q, affine)
    if not torch.equal(slow.frame(x, exact_current_frame=True), fast.frame(x, exact_current_frame=True)):
        raise ValueError('Fast integer output differs from INT64 reference')
    for name in slow.stats:
        for a, b in zip(slow.stats[name], fast.stats[name]):
            if not (torch.equal(a, b) if isinstance(a, torch.Tensor) else a == b):
                raise ValueError('Raw statistics differ from INT64 reference')
    history = []; exacts = []; samples = []; rows = []
    external = content(cfg, 'external_test')
    picks = np.linspace(0, len(test) - 1, min(4, len(test))).round().astype(int)
    images = np.concatenate([np.array(external[:4], copy=True), np.array(test[picks], copy=True)])
    for index, image in enumerate(images):
        xx = torch.from_numpy(image[None]).long(); reference = FastIN(q, affine)
        current = reference.frame(xx, exact_current_frame=True)
        reference = FastIN(q, affine)
        for _ in range(cfg['export']['history_frames']): y = reference.frame(xx)
        delta = float((y.float() - current.float()).abs().mean())
        rows.append(dict(index=index, history_vs_current_mae=delta))
        samples.append(xx[0]); exacts.append(current[0]); history.append(y[0])
    grid(run / 'integer_preview.png', [('photo', torch.stack(samples).float() / 255),
        ('INT8 historical IN', torch.stack(history).float() / 255)])
    errors = []
    for i in range(count):
        xx = torch.from_numpy(np.array(test[i:i + 1], copy=True)).long()
        integer = FastIN(q, affine).frame(xx, exact_current_frame=True)
        floating = model(xx.float() / 255) * 255
        errors.append(float((integer.float() - floating).abs().mean()))
    patterns = []
    backgrounds = []
    for label, value in [('black', 0), ('gray', 128), ('white', 255)]:
        xx = torch.full((1, 3, 144, 256), value, dtype=torch.long)
        reference = FastIN(q, affine)
        for _ in range(30): y = reference.frame(xx)
        yf = y.float() / 255
        patterns.append(dict(scene=label, row_mean_std=float(yf.mean((1, 3)).std()),
            spatial_std=float(yf.flatten(2).std(2).mean())))
        backgrounds.append(y[0])
    # A true 16:9 smooth gradient, without artificial portrait side padding.
    gradient = torch.linspace(64, 192, 144).round().long()[None, None, :, None].expand(1, 3, 144, 256).clone()
    y = FastIN(q, affine).frame(gradient, exact_current_frame=True)
    backgrounds.append(y[0]); patterns.append(dict(scene='native_16_9_vertical_gradient',
        row_mean_step_mae=float((y[:, :, 1:].float() - y[:, :, :-1].float()).abs().mean() / 255)))
    grid(run / 'background_diagnostics.png', [('INT8 background diagnostics', torch.stack(backgrounds).float() / 255)], 4)
    dynamic = []; ref = FastIN(q, affine)
    for frame in range(90):
        image = samples[0] if frame < 30 else samples[1]
        xx = image[None] if frame < 60 else (image[None].float() * .55).round().long()
        result = ref.frame(xx)
        if frame in (0, 14, 29, 30, 44, 59, 60, 74, 89):
            cur = FastIN(q, affine).frame(xx, exact_current_frame=True)
            dynamic.append(dict(frame=frame + 1, history_vs_current_mae=float((cur.float() - result.float()).abs().mean())))
    mapping = json.loads((q / 'rtl_address_map.json').read_text())
    for width in (4, 16, 20):
        restored = b''.join(int(v, 16).to_bytes(width, 'little') for v in (q / f'codec16_rtl_ddr_u{width * 8}.mem').read_text().split())
        if restored != (q / 'codec16_rtl_ddr.bin').read_bytes(): raise ValueError('MEM roundtrip failed')
    report = dict(status='PASS', scan_bytes=24960, affine_bytes=3200, segments=55,
        weight_sha256=sha_file(q / 'codec16_rtl_ddr.bin'), weight_crc32=mapping['crc32'], affine_crc32=zlib.crc32(affine.read_bytes()),
        INT64_bit_exact_samples=1, raw_statistics_bit_exact=True, static_checks=rows,
        all_static_samples_converged=all(r['history_vs_current_mae'] == 0 for r in rows),
        test_count=count, test_mean_qat_vs_integer_mae=float(np.mean(errors)), test_mae=errors,
        dynamic_checks=dynamic, background_diagnostics=patterns, background_quality_manually_accepted=False,
        source_engineering_modified=False, history_trained=False, board_tested=False, directly_flashable=False,
        limitation='Numeric PASS is not a subjective style-quality or motion-stability acceptance.')
    if cfg['paths'].get('target_archive'):
        report['target_abi'] = compare_target_abi(q, cfg['paths']['target_archive'])
    write_json(run / 'validation_report.json', report)
    print(json.dumps({k: report[k] for k in ('status', 'test_count', 'test_mean_qat_vs_integer_mae', 'all_static_samples_converged')}), flush=True)
    return report
