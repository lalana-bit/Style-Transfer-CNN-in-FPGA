"""工程工具路径：环境变量 > 本机配置 > Windows默认安装位置。"""
from pathlib import Path
import json,os

ROOT=Path(__file__).resolve().parents[1]

def tool_path(name):
    default={'efinity':'E:/Efinity','riscv':'E:/Efinity_riscv'}
    configured=json.loads((ROOT/'config/toolchains.json').read_text(encoding='utf-8'))
    local=ROOT/'config/toolchains.local.json'
    if local.exists():configured.update(json.loads(local.read_text(encoding='utf-8')))
    variable={'efinity':'EFINITY_HOME','riscv':'EFINITY_RISCV_HOME'}[name]
    result=Path(os.environ.get(variable) or configured.get(name) or default[name]).resolve()
    if not result.exists():raise FileNotFoundError(f'{name}: {result}; set {variable} or config/toolchains.local.json')
    return result
