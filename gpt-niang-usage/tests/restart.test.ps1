param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
$appDir=Split-Path $TestRoot -Parent
$source=[IO.File]::ReadAllText((Join-Path $appDir 'runtime\restart-widget.ps1'))
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$fn=$ast.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq 'Restart-Widget'},$true)
. ([ScriptBlock]::Create($fn.Extent.Text))
$script:calls=[Collections.Generic.List[string]]::new()
function Get-WidgetSupervisorInfo($AppDir){$script:calls.Add('validate');return @{DataDir='isolated-state'}}
function Get-WidgetSupervisorTask($Info){if($script:missing){return $null};return @{State='Running'}}
function Stop-WidgetSupervisorTask($AppDir){$script:calls.Add('stop-supervisor')}
function Stop-WidgetGui($AppDir,$DataDir){if($DataDir-ne 'isolated-state'){throw 'Wrong state target'};$script:calls.Add('stop-gui')}
function Start-WidgetSupervisorTask($AppDir){$script:calls.Add('start-supervisor')}
Restart-Widget 'isolated-app'
if(($script:calls -join ',')-ne 'validate,stop-supervisor,stop-gui,start-supervisor'){throw 'Unsafe restart ordering'}
$script:calls.Clear();$script:missing=$true
try{Restart-Widget 'isolated-app';throw 'Missing task was not rejected'}catch{if($_.Exception.Message-notlike 'Supervisor task is not installed*'){throw}}
if(($script:calls -join ',')-ne 'validate'){throw 'Missing installation changed runtime state'}
Write-Output 'PASS: restart validates installation, stops supervisor before GUI, restarts without reinstalling, and rejects missing registration without side effects'
