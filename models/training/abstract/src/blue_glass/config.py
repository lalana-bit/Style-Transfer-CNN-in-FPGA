"""All paths are explicit and relative to the configuration file."""
import copy
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load_config(filename):
    filename = Path(filename).resolve()
    cfg = json.loads(filename.read_text(encoding='utf-8-sig'))
    for key, value in cfg['paths'].items():
        if value is not None:
            path = Path(value).expanduser()
            cfg['paths'][key] = str((filename.parent / path).resolve() if not path.is_absolute() else path.resolve())
    cfg['_config_file'] = str(filename)
    if not 0 <= cfg['teacher']['strength'] <= 1:
        raise ValueError('teacher.strength must be in [0, 1]')
    if min(cfg['train']['fp32_steps'], cfg['train']['qat_steps']) < 1:
        raise ValueError('Both FP32 and QAT stages require at least one step')
    for key in ('content', 'magenta', 'vgg', 'style', 'init'):
        source = Path(cfg['paths'][key])
        for output in ('targets', 'run'):
            dest = Path(cfg['paths'][output])
            if dest == source or source in dest.parents or dest in source.parents:
                raise ValueError(f'{output} overlaps read-only input {key}')
    return cfg


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def sha_file(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.tmp')
    temp.write_text(json.dumps(value, indent=2, ensure_ascii=False), encoding='utf-8')
    temp.replace(path)


def stage_id(cfg, stage):
    sections = {'targets': ('teacher',), 'train': ('teacher', 'train', 'loss'), 'export': ('export',)}[stage]
    return fingerprint({k: copy.deepcopy(cfg[k]) for k in sections})
