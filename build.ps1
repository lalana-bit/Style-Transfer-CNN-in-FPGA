param(
    [ValidateSet('check','cpu','fpga','package')]
    [string]$Stage='check',
    [string]$Python='python'
)
$ErrorActionPreference='Stop'
& $Python (Join-Path $PSScriptRoot 'tools\build.py') $Stage
if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
