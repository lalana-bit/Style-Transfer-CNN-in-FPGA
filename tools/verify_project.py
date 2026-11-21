"""检查当前工程路径、软核初始化、运行权重及交付固件；不综合、不烧录。"""
from pathlib import Path
import hashlib
import json
import xml.etree.ElementTree as ET
import zlib

ROOT = Path(__file__).resolve().parents[1]

def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    info = json.loads((ROOT/'config/project.json').read_text(encoding='utf-8'))
    project = ROOT/info['project']
    hardware = project.parent
    for node in ET.parse(project).iter():
        tag = node.tag.split('}')[-1]
        if tag in ['design_file', 'sdc_file', 'peri_file', 'default_peri_file']:
            name = node.attrib.get('name')
            assert not name or (hardware/name).is_file(), name
        if tag == 'ip':
            assert (hardware/node.attrib['path']).is_file()
    bit = hardware/'outflow/ti60f225_oob.bit'
    image = ROOT/info['firmware']
    assert sha256(bit) == info['bit_sha256'], 'BIT hash mismatch'
    assert sha256(image) == info['hex_sha256'], 'Flash HEX hash mismatch'
    flash = bytes.fromhex(image.read_text())
    prefix = bytes.fromhex((hardware/'outflow/ti60f225_oob.hex').read_text())
    assert flash[:len(prefix)] == prefix
    app = hardware/'software/cnn_weight_loader'
    cpu = (app/'build/cnn_weight_loader.bin').read_bytes()
    assert len(cpu) <= 16384
    padded = cpu + bytes(16384-len(cpu))
    for lane in range(4):
        path = hardware/'ip/ip/cnn_boot_soc'/f'EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{lane}.bin'
        actual = bytes(int(word, 2) for word in path.read_text().splitlines())
        assert actual == padded[lane::4], f'CPU RAM lane {lane} mismatch'
    header = (app/'src/cnn_style_banks.h').read_text(encoding='utf-8-sig')
    for index, name in enumerate(['starry', 'cubist', 'abstract', 'mosaic']):
        folder = ROOT/'weights/runtime'/name
        weight = (folder/'weights.bin').read_bytes()
        affine = (folder/'in.bin').read_bytes()
        assert len(weight) == 63296 and len(affine) == 3200
        assert f'0x{zlib.crc32(weight):08x}u' in header
        address = [0x400000, 0x440000, 0x460000, 0x480000][index]
        in_address = [0x420000, 0x450000, 0x470000, 0x490000][index]
        assert flash[address:address+len(weight)] == weight
        assert flash[in_address:in_address+len(affine)] == affine
    assert len(flash) == 0x490000+3200
    assert not info['includes_static_images'] and not info['includes_voice_control']
    assert (app/'../../../software/cnn_boot_soc/software/standalone/common/bsp.mk').resolve().is_file()
    for model in json.loads((ROOT/'config/models.json').read_text(encoding='utf-8')):
        for path, expected in model.get('checkpoints', {}).items():
            assert sha256(ROOT/path) == expected, path
    manifest_path = ROOT/'reports/integrity.json'
    if manifest_path.exists():
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        for path, expected in manifest.items():
            assert sha256(ROOT/path) == expected, path
    print('PASS project paths, BSP, CPU RAM, four styles, training checkpoints, BIT/HEX and integrity')

if __name__ == '__main__':
    main()
