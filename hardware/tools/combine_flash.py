"""用Efinity官方合并器组合FPGA、软核初始化和四风格权重，不包含静图资源。"""
from pathlib import Path
import json,sys,subprocess,os,zlib,hashlib


def main():
    variant=Path(__file__).resolve().parents[1]
    root=variant.parent
    sys.path.insert(0,str(root/'tools'))
    from toolchains import tool_path
    efinity=tool_path('efinity')
    build=variant/'build/flash_package';build.mkdir(parents=True,exist_ok=True)
    output=root/'firmware/FLASH_CNN_CAMERA_START_0x00000000.hex'
    output.parent.mkdir(parents=True,exist_ok=True)
    header=(variant/'software/cnn_weight_loader/src/cnn_style_banks.h').read_text(encoding='utf-8-sig')
    assert '#define WEIGHT_BYTES 63296u' in header
    fpga=variant/'outflow/ti60f225_oob.hex'
    prefix=bytes.fromhex(fpga.read_text())
    assert 0<len(prefix)<0x400000,'FPGA配置与权重区重叠'
    full=bytearray(b'\xff'*(0x490000+3200))
    full[:len(prefix)]=prefix
    regions=[(0,len(prefix))];inputs=[(0,fpga)]

    def add(name,data,address):
        end=address+len(data)
        assert all(end<=lo or address>=hi for lo,hi in regions),'Flash地址重叠'
        regions.append((address,end));full[address:end]=data
        path=build/(name+'.hex')
        path.write_text(''.join(f'{v:02X}\n' for v in data),encoding='ascii')
        inputs.append((address,path))

    for i,name in enumerate(['starry','cubist','abstract','mosaic']):
        folder=root/'weights/runtime'/name
        weight=(folder/'weights.bin').read_bytes()
        affine=(folder/'in.bin').read_bytes()
        assert len(weight)==63296 and len(affine)==3200
        assert f'0x{zlib.crc32(weight):08x}u' in header,'加载程序CRC与权重不符'
        add(name+'_W',weight,[0x400000,0x440000,0x460000,0x480000][i])
        add(name+'_IN',affine,[0x420000,0x450000,0x470000,0x490000][i])
    env=dict(os.environ,EFINITY_HOME=str(efinity),EFXPGM_HOME=str(efinity/'pgm'),PYTHONHOME=str(efinity/'python311'),TCL_LIBRARY=str(efinity/'lib/tcl8.6'))
    env['PATH']=str(efinity/'python311/bin')+os.pathsep+str(efinity/'bin')+os.pathsep+env.get('PATH','')
    cmd=[str(efinity/'python311/bin/python.exe'),str(efinity/'pgm/bin/multi_image_merger.py'),'-m','generic_comb_image']
    for address,path in sorted(inputs):cmd+=['-ifile',str(path),'-iaddr',f'0x{address:08x}']
    candidate=build/'candidate.hex';cmd+=['-o',str(candidate)]
    result=subprocess.run(cmd,env=env,capture_output=True)
    (build/'combine.log').write_bytes(result.stdout+result.stderr)
    assert result.returncode==0,(result.stdout+result.stderr)[-2000:]
    assert bytes.fromhex(candidate.read_text())==full and len(full)<0x800000
    output.write_bytes(candidate.read_bytes())
    catalog_path=root/'config/project.json'
    catalog=json.loads(catalog_path.read_text())
    catalog['firmware']=output.relative_to(root).as_posix()
    catalog['includes_static_images']=False
    catalog['includes_voice_control']=False
    catalog['bit_sha256']=hashlib.sha256((variant/'outflow/ti60f225_oob.bit').read_bytes()).hexdigest()
    catalog['hex_sha256']=hashlib.sha256(output.read_bytes()).hexdigest()
    catalog_path.write_text(json.dumps(catalog,indent=2)+'\n')
    print(str(output))
    print(f'PASS {len(full)} bytes; start=0; sha256={hashlib.sha256(output.read_bytes()).hexdigest()}')


if __name__=='__main__':
    main()
