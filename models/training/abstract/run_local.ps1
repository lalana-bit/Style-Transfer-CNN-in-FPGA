param(
    [ValidateSet('check','targets','train','export','validate','all')]
    [string]$Action = 'check',
    [string]$Config = '',
    [string]$Python = 'python',
    [string]$TorchDeps = '',
    [switch]$Resume
)
$ErrorActionPreference = 'Stop'
if (-not $Config) { $Config = Join-Path $PSScriptRoot 'configs/train.json' }
$settings = Get-Content -Raw -Encoding UTF8 -LiteralPath $Config | ConvertFrom-Json
if (-not $TorchDeps -and $settings.runtime) { $TorchDeps = $settings.runtime.torch_deps }
if ($Resume -and $Action -ne 'train') { throw '-Resume is supported only for train' }
$previousPythonPath = $env:PYTHONPATH
try {
    if ($TorchDeps) {
        if (-not (Test-Path -LiteralPath $TorchDeps)) { throw "Configured PyTorch dependency directory is missing: $TorchDeps" }
        $env:PYTHONPATH = $TorchDeps
    }
    $trainingArgs = @('-B', (Join-Path $PSScriptRoot 'run.py'), '--config', $Config, $Action)
    if ($Resume) { $trainingArgs += '--resume' }
    & $Python @trainingArgs
    $resultCode = $LASTEXITCODE
}
finally { $env:PYTHONPATH = $previousPythonPath }
exit $resultCode
