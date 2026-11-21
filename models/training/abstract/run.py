"""Unified training entry. Subcommands execute only when explicitly invoked."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT.parents[1] / 'common'))
sys.path.insert(0, str(ROOT / 'src'))
from blue_glass.config import load_config


def main():
    parser = argparse.ArgumentParser(description='Ti60 blue-glass training and export')
    parser.add_argument('--config', default=str(ROOT / 'configs/train.json'))
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('check', help='Check configured paths and runtime; does not train')
    prepare = sub.add_parser('prepare', help='Prepare uint8 NCHW data from an image directory')
    prepare.add_argument('--images', required=True)
    sub.add_parser('targets', help='Generate/reuse verified Magenta targets in a separate TF interpreter')
    sub.add_parser('targets-worker', help=argparse.SUPPRESS)
    train = sub.add_parser('train', help='Train FP32 and QAT')
    train.add_argument('--resume', action='store_true')
    train.add_argument('--stop-after', type=int, help='Optional step boundary for a short run/resume')
    for name in ('export', 'validate'):
        cmd = sub.add_parser(name)
        cmd.add_argument('--checkpoint', help='Override the default run/best_qat.pt')
    infer = sub.add_parser('infer', help='CPU integer replay; portrait padding is opt-in')
    infer.add_argument('--input', required=True)
    infer.add_argument('--output', required=True)
    infer.add_argument('--resize', choices=('fit', 'contain'), default='fit')
    infer.add_argument('--frames', type=int, default=60)
    infer.add_argument('--current', action='store_true', help='Use exact-current IN instead of static historical warmup')
    sub.add_parser('all', help='targets -> train -> export -> validate; uses a new run directory')
    args = parser.parse_args()
    cfg = load_config(args.config)
    if args.command == 'check':
        import torch
        print(json.dumps(dict(paths={k: {'path': v, 'exists': Path(v).exists()} for k, v in cfg['paths'].items() if v},
            torch=torch.__version__, CUDA=torch.cuda.is_available(), requested_device=cfg['train']['device']), indent=2))
    elif args.command == 'prepare':
        from blue_glass.data import prepare_images
        prepare_images(cfg, args.images, cfg['paths']['content'])
    elif args.command == 'targets-worker':
        from blue_glass.teacher import generate
        generate(cfg)
    else:
        if args.command in ('targets', 'all'):
            teacher_env = os.environ.copy()
            teacher_env.pop('PYTHONPATH', None)
            subprocess.run([cfg['paths']['teacher_python'], '-B', str(ROOT / 'run.py'),
                '--config', cfg['_config_file'], 'targets-worker'], check=True, env=teacher_env)
        if args.command in ('train', 'all'):
            from blue_glass.train import train
            train(cfg, resume=getattr(args, 'resume', False), stop_after=getattr(args, 'stop_after', None))
        if args.command in ('export', 'all'):
            from blue_glass.export import export_model
            export_model(cfg, getattr(args, 'checkpoint', None))
        if args.command in ('validate', 'all'):
            from blue_glass.validate import validate
            validate(cfg, getattr(args, 'checkpoint', None))
        if args.command == 'infer':
            from blue_glass.inference import infer
            infer(cfg, args.input, args.output, args.resize, args.frames, args.current)


if __name__ == '__main__':
    main()
