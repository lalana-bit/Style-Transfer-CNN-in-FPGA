"""Optional explicit download of large teacher/VGG assets; never run on import."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'src'))
from blue_glass.config import load_config


def download(url, path, expected):
    path = Path(path)
    def matches():
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        return digest.startswith(expected)
    if path.exists():
        if not matches(): raise ValueError(f'Existing asset does not match expected hash: {path}')
        print('Already present', path)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.download')
    urllib.request.urlretrieve(url, temporary)
    digest = hashlib.sha256(temporary.read_bytes()).hexdigest()
    if not digest.startswith(expected): raise ValueError(f'Download hash mismatch: {url}')
    temporary.replace(path)
    print('Downloaded', path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', default=str(ROOT / 'configs/train.json'))
    args = parser.parse_args(); cfg = load_config(args.config)
    source = json.loads((ROOT / 'provenance/magenta_weights.json').read_text())
    for row in source['files']:
        download('https://raw.githubusercontent.com/deepeshdm/Neural-Style-Transfer/main/model/' + row['file'],
            Path(cfg['paths']['magenta']) / row['file'], row['sha256'])
    download('https://download.pytorch.org/models/vgg16-397923af.pth', cfg['paths']['vgg'], '397923af')


if __name__ == '__main__':
    main()
