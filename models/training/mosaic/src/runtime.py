"""Configuration is loaded before importing the training engine."""
from pathlib import Path
import sys
PACKAGE = Path(__file__).resolve().parent.parent
ROOT = PACKAGE / 'outputs'
CONFIG = {}
sys.dont_write_bytecode = True

def configure(config):
    global ROOT
    CONFIG.clear()
    CONFIG.update(config)
    ROOT = Path(config['paths']['work_dir'])
    ROOT.mkdir(parents=True, exist_ok=True)

def asset(name):
    return Path(CONFIG['paths'][name])

def validate_data():
    import numpy as np
    for split in ['train', 'val', 'test', 'external_test']:
        content=np.load(asset('data_dir')/f'{split}_content.npy',mmap_mode='r')
        target=np.load(asset('data_dir')/f'{split}_target.npy',mmap_mode='r')
        if content.shape!=target.shape or content.ndim!=4 or content.shape[1:]!=(3,144,256):
            raise ValueError(f'{split}: expected matching N x 3 x 144 x 256 arrays')
        if content.dtype!=np.uint8 or target.dtype!=np.uint8:
            raise ValueError(f'{split}: arrays must be uint8 RGB')
        minimum=101 if split in ['val','test'] else 1
        if len(content)<minimum:
            raise ValueError(f'{split}: at least {minimum} images are required')
