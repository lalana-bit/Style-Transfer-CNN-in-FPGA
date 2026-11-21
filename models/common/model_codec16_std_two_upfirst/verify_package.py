"""Verify a deployed style package, runtime payload and integer fixtures."""
from pathlib import Path
import hashlib
import json
import struct
import zlib

import numpy as np
from PIL import Image
import torch

from .integer_in15 import IntegerIN15, verify_packed
from .model import ARCHITECTURE, IN_SITES, load_checkpoint
from .streaming_reference import StreamingINReference
from .packing import residual_table
from .hardware_qat import configure


def image(path):
    with Image.open(path) as im:
        return torch.from_numpy(np.array(im.convert('RGB'))).permute(2,0,1)[None].long()


def main(package: Path) -> None:
    torch.set_num_threads(4)
    torch.backends.mkldnn.enabled = False
    sums = json.loads((package/'SHA256SUMS.json').read_text(encoding='utf8'))
    for name,digest in sums.items():
        assert hashlib.sha256((package/name).read_bytes()).hexdigest()==digest,name
    d = package/'model'
    bank = json.loads((package/'integration/style_bank.json').read_text(encoding='utf8'))
    layout = verify_packed(d)
    raw = (d/'codec16_rtl_ddr.bin').read_bytes()
    for width in (4,16,20):
        data = b''.join(int(v,16).to_bytes(width,'little') for v in (d/f'codec16_rtl_ddr_u{width*8}.mem').read_text(encoding='utf8').split())
        assert data[:len(raw)]==raw and not any(data[len(raw):])
    for name in ('FP32_best.pt','QAT_master.pt'):
        model,payload = load_checkpoint(package/'checkpoints'/name)
        assert payload['trained_for_upfirst'] and payload['trained_for_in']
        assert payload['architecture']==ARCHITECTURE
        assert payload['style']==bank['style']
        assert payload['in_sites']==list(IN_SITES) and payload['input_hw']==[144,256]
        assert payload['qat']==(name=='QAT_master.pt')
        assert sum(p.numel() for p in model.parameters())==53955
    configure(model)
    manifest = json.loads((d/'quantization_manifest.json').read_text(encoding='utf8'))
    checkpoint_sha = hashlib.sha256((package/'checkpoints/QAT_master.pt').read_bytes()).hexdigest()
    assert manifest['checkpoint_sha256']==checkpoint_sha
    assert manifest['trained_architecture']==ARCHITECTURE and manifest['trained_for_upfirst']
    weights = (d/'weights_int8.bin').read_bytes()
    bundle = torch.load(d/'INT8_tensor_bundle.pt',map_location='cpu',weights_only=True)
    assert bundle['checkpoint_sha256']==checkpoint_sha
    assert bundle['architecture']==ARCHITECTURE
    affine = bytearray()
    for i,((name,conv,sx,sy),row) in enumerate(zip(model.layer_contract(),manifest['layers'],strict=True)):
        qw,_,ws = conv.integer_parameters()
        assert name==row['name']
        assert qw.to(torch.int8).numpy().tobytes()==weights[row['weight_offset']:row['weight_offset']+row['weight_bytes']]
        assert torch.equal(qw.to(torch.int8),bundle['layers'][name]['weights'])
        if i<15:
            norm = model.get_submodule(IN_SITES[i]).norm
            g = np.rint(norm.weight.detach().numpy()/float(sy.scale)*256).astype(np.int64)
            b = np.rint(norm.bias.detach().numpy()/float(sy.scale)*256).astype(np.int64)
            eps = np.maximum(65536,np.rint(norm.eps/np.square(float(sx.scale)*ws.numpy()))).astype(np.int64)
            affine.extend(b''.join(struct.pack('<HhI',int(gg),int(bb),int(ee)) for gg,bb,ee in zip(g,b,eps)))
    assert bytes(affine) == (d / 'IN15_TRAINED_AFFINE.bin').read_bytes()
    assert bank['architecture']==ARCHITECTURE
    assert bank['weight_crc32']==zlib.crc32(raw)
    assert bank['affine_crc32']==zlib.crc32(affine)
    runtime = package.parents[2] / 'weights/runtime' / bank['style']
    assert (runtime / 'weights.bin').read_bytes() == raw
    assert (runtime / 'in.bin').read_bytes() == bytes(affine)
    assert (runtime / 'rom_u160.mem').read_bytes() == (d / 'codec16_rtl_ddr_u160.mem').read_bytes()
    runtime_layout = json.loads((runtime / 'layout.json').read_text(encoding='utf-8'))
    assert layout['segments'] == runtime_layout['segments']
    for i in range(5):
        seg = layout['segments'][48+i]
        assert raw[seg['offset']:seg['offset']+seg['bytes']]==residual_table(manifest,i)
    x = image(d/'seed_input.png')
    with torch.inference_mode():
        current = IntegerIN15(d)(x)
        assert torch.equal(current,image(d/'seed_INT8_current.png'))
        slow = StreamingINReference(d,d/'IN15_TRAINED_AFFINE.bin')
        assert torch.equal(current,slow.frame(x,exact_current_frame=True))
        for schedule in ('groups','serial'):
            reference = IntegerIN15(d,schedule)
            for _ in range(60):
                result = reference(x,exact=False)
            assert torch.equal(result,image(d / 'seed_INT8_current.png'))
    print(json.dumps(dict(status='PASS',hash_files=len(sums),architecture=ARCHITECTURE,
                          scan_bytes=63296,affine_bytes=3200,checkpoint_and_INT8_equal=True,
                          current_and_INT64_equal=True,grouped_and_serial_history60=True,
                          board_tested=False)))


if __name__=='__main__':
    main()
