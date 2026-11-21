param(
 [ValidateSet('check','prepare','train','export','selftest')][string]$Stage='check',
 [string]$Python='python',
 [string]$Config=(Join-Path $PSScriptRoot 'config.example.json'),
 [string]$Run='mosaic_texture_v2'
)
$ErrorActionPreference='Stop'
$arguments=@((Join-Path $PSScriptRoot 'mosaic.py'),'--config',$Config,$Stage)
if($Stage -in @('train','export')){$arguments+=@('--run',$Run)}
& $Python @arguments
exit $LASTEXITCODE
