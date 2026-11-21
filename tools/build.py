"""唯一工程的构建入口；常规复现优先使用Efinity GUI，不自动烧录。"""
from pathlib import Path
import argparse,subprocess,sys,os
from toolchains import ROOT,tool_path

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage',choices=['check','cpu','fpga','package'],nargs='?',default='check')
    args=parser.parse_args()
    project=ROOT/'hardware'
    if args.stage=='check':
        subprocess.run([sys.executable,str(ROOT/'tools/verify_project.py')],check=True)
        return
    if args.stage in ['cpu','package']:
        script=project/'tools'/('build_cpu.py' if args.stage=='cpu' else 'combine_flash.py')
        subprocess.run([sys.executable,str(script)],cwd=project,check=True)
        return
    efinity=tool_path('efinity')
    env=dict(os.environ)
    env.pop('EFINITY_HOME',None)
    env['EFINITY_USER_DIR']=str(ROOT/'build/efinity_user')
    env['PYTHONDONTWRITEBYTECODE']='1'
    for flow in ['map','interface','pnr','pgm']:
        subprocess.run([str(efinity/'bin/python3.bat'),str(efinity/'scripts/efx_run.py'),
                        'ti60f225_oob','--flow',flow,'--prj'],cwd=project,env=env,check=True)
    print('Build complete. Inspect current WNS before programming.')

if __name__=='__main__':
    main()
