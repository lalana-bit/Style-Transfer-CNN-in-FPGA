"""Single entry point for Mosaic training, validation and INT8 export."""
from pathlib import Path
import argparse
import importlib.metadata
import json
import sys

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--config', type=Path, default=HERE/'config.example.json')
    p.add_argument('--deps', type=Path, help='Optional isolated Python dependency directory')
    sub = p.add_subparsers(dest='command', required=True)
    sub.add_parser('check', help='Check configured files, data and GPU availability')
    sub.add_parser('prepare', help='Generate disjoint content/teacher training arrays')
    train = sub.add_parser('train', help='Train FP32 then calibrate and fine-tune QAT')
    train.add_argument('--run')
    train.add_argument('--init', type=Path)
    train.add_argument('--steps', type=int)
    train.add_argument('--qat-steps', type=int)
    export = sub.add_parser('export', help='Export and validate current-frame and historical integer IN')
    export.add_argument('--run')
    sub.add_parser('selftest', help='Real FP32/QAT optimization and integer export on two images')
    a = p.parse_args()
    config_file = a.config.resolve()
    config = json.loads(config_file.read_text(encoding='utf-8-sig'))
    for key, value in config['paths'].items():
        path = Path(value).expanduser()
        config['paths'][key] = str((config_file.parent/path).resolve() if not path.is_absolute() else path)
    expected = {'content','gram','coarse_gram','patch','palette','chroma','hf_excess','alias_excess','texture','tv','layout'}
    if set(config['loss_weights']) != expected:
        p.error('loss_weights must contain exactly: '+', '.join(sorted(expected)))
    if any(v < 0 for v in config['loss_weights'].values()):
        p.error('Loss weights must be nonnegative')
    if a.deps:
        sys.path.insert(0,str(a.deps.resolve()))
    sys.path.insert(0,str(HERE/'src'))
    sys.path.insert(0,str(HERE.parents[1]/'common'))
    from runtime import configure
    configure(config)
    if a.command == 'check':
        import torch
        import torchvision
        import numpy as np
        paths = config['paths']
        report = {'torch':torch.__version__, 'torchvision':torchvision.__version__,
                  'cuda_available':torch.cuda.is_available(),
                  'gpu':torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
                  'files':{k:Path(paths[k]).is_file() for k in ['style_image','teacher_weights','vgg_weights','initial_checkpoint']}}
        arrays = {}
        for split in ['train','val','test','external_test']:
            for kind in ['content','target']:
                file=Path(paths['data_dir'])/f'{split}_{kind}.npy'
                if file.is_file():
                    ar=np.load(file,mmap_mode='r')
                    arrays[file.name]={'shape':list(ar.shape),'dtype':str(ar.dtype)}
        report['prepared_arrays']=arrays
        report['data_ready']=all(f'{s}_{k}.npy' in arrays for s in ['train','val','test','external_test'] for k in ['content','target'])
        if report['data_ready']:
            from runtime import validate_data
            try:
                validate_data()
            except (ValueError, OSError) as error:
                report['data_ready']=False
                report['data_error']=str(error)
        report['ready_to_train']=all(report['files'].values()) and report['data_ready'] and report['cuda_available']
        print(json.dumps(report,indent=2))
        return 0 if report['ready_to_train'] else 1
    import torch
    if a.command in ['prepare','train','selftest'] and not torch.cuda.is_available():
        p.error('Training/data preparation requires a CUDA PyTorch installation and GPU. See README.md.')
    if a.command == 'prepare':
        from engine import prepare
        prepare()
    elif a.command == 'train':
        from engine import main as train_main
        c = config['training']
        options=['--run', a.run or c['run'], '--steps',str(a.steps if a.steps is not None else c['steps']),
                 '--qat-steps',str(a.qat_steps if a.qat_steps is not None else c['qat_steps']), '--strength',str(c['strength'])]
        if a.init:
            options+=['--init',str(a.init.resolve())]
        train_main(options)
    elif a.command == 'export':
        from export_validate import main as export_main
        export_main(['--run',a.run or config['training']['run']])
    elif a.command == 'selftest':
        from selftest import main as selftest_main
        selftest_main()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
