"""Export matching 24,960B scan + 3,200B IN parameters; no project binding."""
import json
import struct
from pathlib import Path
import numpy as np
import torch
from model_codec16_in.model import load_checkpoint, canonicalize_gamma, IN_SITES
from model_codec16_in.streaming_reference import coefficients
from model_codec16.packing import pack
from .config import write_json
from .data import content
from .hardware import FastIN, write_export


@torch.inference_mode()
def export_model(cfg, checkpoint=None):
    run = Path(cfg['paths']['run'])
    source = Path(checkpoint) if checkpoint else run / 'best_qat.pt'
    output = run / 'candidate'
    output.mkdir(parents=True, exist_ok=False)
    torch.set_num_threads(cfg['export']['cpu_threads'])
    torch.backends.mkldnn.enabled = False
    torch.backends.cuda.matmul.allow_tf32 = False; torch.backends.cudnn.allow_tf32 = False
    model, meta = load_checkpoint(source)
    if not meta.get('qat'):
        raise ValueError('Use a QAT checkpoint; FP32 does not contain calibrated fixed activation scales')
    model = canonicalize_gamma(model).eval()
    for name in IN_SITES: model.get_submodule(name).conv.bias.zero_()
    manifest = write_export(model, meta, output, source)
    manifest.update(quantization='QAT per-output-channel weights; hidden activation scale 6/127',
        calibration_inputs='evenly distributed training samples only', calibration_brightness=[.5, 1., 1.5])
    write_json(output / 'quantization_manifest.json', manifest)
    train = content(cfg, 'train')
    ids = np.linspace(0, len(train) - 1, min(cfg['export']['calibration_count'], len(train))).astype(int)
    reference = FastIN(output, output / 'IN15_TRAINED_AFFINE.bin')
    pooled = {}
    for index in ids:
        x = torch.from_numpy(np.array(train[index:index + 1], copy=True)).long()
        reference.frame(x, exact_current_frame=True)
        for name, (sums, squares, n) in reference.stats.items():
            if name in pooled:
                a, b, count = pooled[name]; pooled[name] = (a + sums, b + squares, count + n)
            else: pooled[name] = (sums.clone(), squares.clone(), n)
    bias = bytearray((output / 'bias_int32.bin').read_bytes())
    requant = bytearray((output / 'requant_int32.bin').read_bytes())
    for row in manifest['layers'][:15]:
        sums, squares, n = pooled[row['name']]
        for channel, (s1, s2, affine) in enumerate(zip(sums, squares, reference.affine[row['name']])):
            b, mult, shift = coefficients(int(s1), int(s2), n, *affine)
            struct.pack_into('<i', bias, row['bias_offset'] + 4 * channel, b)
            struct.pack_into('<ii', requant, row['requant_offset'] + 8 * channel, mult, shift)
    (output / 'bias_int32.bin').write_bytes(bias)
    (output / 'requant_int32.bin').write_bytes(requant)
    mapping = pack(output, output)
    if mapping['bytes'] != 24960 or len(mapping['segments']) != 55:
        raise ValueError('Exported image does not match hardware ABI')
    if (output / 'IN15_TRAINED_AFFINE.bin').stat().st_size != 3200:
        raise ValueError('Incorrect IN record length')
    write_json(output / 'export_context.json', dict(checkpoint=str(source.resolve()),
        source_engineering_modified=False, calibration_indices=ids.tolist(),
        directly_flashable=False, firmware_rebuilt=False, board_tested=False))
    print('Export complete', output, flush=True)


def compare_target_abi(candidate, archive):
    import re
    import zipfile
    from .config import sha_file
    candidate = Path(candidate)
    mapping = json.loads((candidate / 'rtl_address_map.json').read_text())
    manifest = json.loads((candidate / 'quantization_manifest.json').read_text())
    with zipfile.ZipFile(archive) as z:
        matches = [n for n in z.namelist() if n.endswith('/project/rtl/cnn_accel/rtl/cnn_config.vh')]
        if len(matches) != 1: raise ValueError('Target archive root is ambiguous')
        prefix = matches[0].removesuffix('project/rtl/cnn_accel/rtl/cnn_config.vh')
        config = z.read(matches[0]).decode('utf-8-sig')
        old = json.loads(z.read(prefix + 'weights/starry_e012/quantization_manifest.json'))
        units = list(reversed([int(v) for v in re.findall(r"16'd(\d+)", re.search(r'`define CNN_TRAINED_SEG_UNITS ([^\n]+)', config)[1])]))
        types = list(reversed([int(v) for v in re.findall(r"2'd(\d+)", re.search(r'`define CNN_TRAINED_SEG_TYPES ([^\n]+)', config)[1])]))
        if units != [s['units'] for s in mapping['segments']]: raise ValueError('Segment units differ')
        if types != [0 if s['width'] == 8 else 2 for s in mapping['segments']]: raise ValueError('Segment types differ')
        if len(old['layers']) != len(manifest['layers']) or len(old['layers']) != 16: raise ValueError('Layer count mismatch')
        for row, original in zip(manifest['layers'], old['layers']):
            for key in ('name', 'weight_shape', 'groups', 'stride', 'padding', 'padding_mode', 'upsample_before'):
                if row.get(key) != original.get(key): raise ValueError(f'Geometry differs: {row["name"]} {key}')
    return dict(target_sha256=sha_file(archive), all_16_layers_match=True, all_55_segments_match=True,
        archive_modified=False, board_tested=False)
