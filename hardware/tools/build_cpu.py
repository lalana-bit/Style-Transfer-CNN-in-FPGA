"""Build camera/weight firmware and update the EXISTING four Sapphire RAM lanes.

Run this before FPGA synthesis. No Flash or FPGA hardware is programmed.
--check-only checks the current firmware/RAM without writing any file.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    project = root
    app = root/'software/cnn_weight_loader'
    ip = project/'ip/ip/cnn_boot_soc'
    if not args.check_only:
        import sys
        sys.path.insert(0,str(root.parent/'tools'))
        from toolchains import tool_path
        sdk = tool_path('riscv')
        env = dict(os.environ)
        env['PATH'] = str(sdk/'toolchain/bin')+os.pathsep+str(sdk/'build_tools/bin')+os.pathsep+env.get('PATH', '')
        subprocess.run([str(sdk/'build_tools/bin/make.exe'), '-B', '-j2', 'OBJDIR=build'],
                       cwd=app, env=env, check=True)
    platform_ip = ip
    settings = json.loads((platform_ip/'settings.json').read_text())
    capacity = int(settings['conf']['OCRSize'])
    firmware = (app/'build/cnn_weight_loader.bin').read_bytes()
    # 根据链接结果检查代码、数据和原有 2KiB 栈，避免用 BIN 长度误算可用空间。
    memory_map = (app/'build/cnn_weight_loader.map').read_text()
    region = re.search(r'^ram\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)', memory_map, re.M)
    stack = re.search(r'^\.stack\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)', memory_map, re.M)
    if not region or not stack:
        raise RuntimeError('Missing RAM/stack allocation in linker map')
    origin, extent = (int(v,16) for v in region.groups())
    stack_start, stack_bytes = (int(v,16) for v in stack.groups())
    if (not firmware or capacity%4 or extent!=capacity or stack_bytes<2048 or
            len(firmware)>stack_start-origin or stack_start+stack_bytes>origin+capacity):
        raise RuntimeError('Firmware/data/stack exceed the existing CPU RAM')
    generated = (platform_ip/'cnn_boot_soc.v').read_text(encoding='utf-8-sig')
    for lane in range(4):
        if not re.search(rf'reg\s+\[7:0\]\s+ram_symbol{lane}\s+\[0:{capacity//4-1}\]', generated):
            raise RuntimeError('Unexpected CPU RAM layout; do not overwrite initialization')
    padded = firmware+bytes(capacity-len(firmware))
    digest = lambda data: hashlib.sha256(data).hexdigest()
    rows = []
    for lane in range(4):
        target = ip/f'EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{lane}.bin'
        text = ''.join(f'{byte:08b}\n' for byte in padded[lane::4])
        if not args.check_only:
            target.write_text(text)
        actual = bytes(int(word, 2) for word in target.read_text().splitlines())
        if actual != padded[lane::4]:
            raise RuntimeError('CPU RAM does not match firmware: '+str(target))
        rows.append(dict(path=target.relative_to(project).as_posix(), sha256=digest(target.read_bytes())))
    if not args.check_only:
        metadata = dict(firmware_bytes=len(firmware), ram_bytes=capacity,
                        firmware_sha256=digest(firmware), cpu_ram=rows, hardware_programmed=False)
        (app/'build/camera_ram_verified.json').write_text(json.dumps(metadata, indent=2))
        manifest_path = project/'install_manifest.json'
        if manifest_path.exists():
            manifest = json.loads(manifest_path.read_text())
            for row in manifest['files']:
                path = row['path']
                if path.startswith('embedded_sw/') or path in {r['path'] for r in rows}:
                    row['sha256'] = digest((project/path).read_bytes())
            manifest['cpu_ram'] = rows
            manifest['synthesis_run'] = False
            manifest['hardware_programmed'] = False
            manifest_path.write_text(json.dumps(manifest, indent=2))
    print(f'CPU firmware/RAM verified: {len(firmware)}/{capacity} bytes; '+digest(firmware))
    if not args.check_only:
        print('Next: rebuild this variant in Efinity, then run tools/combine_flash.py.')


if __name__ == '__main__':
    main()
