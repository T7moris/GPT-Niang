param([string]$Template=(Join-Path $PSScriptRoot 'manual-install.ps1'),[string]$Updater=(Join-Path (Split-Path $PSScriptRoot -Parent) 'gpt-niang-usage\runtime\update-ui.ps1'))
$ErrorActionPreference='Stop'
$checks=0
function Assert($Condition,[string]$Message){if(!$Condition){throw $Message};$script:checks++}
$global:manualInstallFixture=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-manual-install-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path (Join-Path $global:manualInstallFixture 'runtime') -Force
$global:manualInstallCalls=[Collections.Generic.List[string]]::new()
$fixtureModule=@'
function Get-WidgetInstallPreflight($SourceDir,$AppDir){
  $global:manualInstallCalls.Add('preflight')
  return @{appDir=$AppDir;dataDir=(Join-Path $global:manualInstallFixture 'state');startupShortcut=(Join-Path $global:manualInstallFixture 'startup.lnk');codexPath=(Join-Path $global:manualInstallFixture 'codex.cmd');nodePath='unused-node.exe';marketplaceRoot=$global:manualInstallFixture;version='1.3.5'}
}
function Get-WidgetUpdateAgentDir {return (Join-Path $global:manualInstallFixture 'agent')}
function Enter-WidgetUpdateLock {$global:manualInstallCalls.Add('lock');return @{token='test'}}
function Exit-WidgetUpdateLock($Lock){$global:manualInstallCalls.Add('unlock')}
function Read-WidgetUpdateJson($File){if(Test-Path -LiteralPath $File){return (Get-Content -LiteralPath $File -Raw -Encoding UTF8|ConvertFrom-Json)};return $null}
function Write-WidgetSupervisorJson($File,$Value){$null=New-Item -ItemType Directory -Path (Split-Path $File -Parent) -Force;[IO.File]::WriteAllText($File,($Value|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
function Stop-WidgetSupervisorTask($AppDir,$Configuration){$global:manualInstallCalls.Add('stop-task')}
function Stop-WidgetGui($AppDir,$DataDir){$global:manualInstallCalls.Add('stop-gui')}
function Unregister-WidgetSupervisorTask($AppDir){
  if(!(Test-Path -LiteralPath (Join-Path $AppDir 'installation.json'))){throw 'Task identity lookup requires installation.json even on a fresh install'}
  $global:manualInstallCalls.Add('remove-task')
}
function Install-WidgetUpdateAgent($AppDir,$DataDir){$global:manualInstallCalls.Add('prepare-agent')}
function Assert-WidgetPluginRegistration($Codex,$Version){$global:manualInstallCalls.Add('verify-plugin')}
function Register-WidgetSupervisorTask {throw 'Manual installation must not register a startup task'}
'@
try{
  $install=Join-Path $global:manualInstallFixture 'Install.ps1'
  [IO.File]::WriteAllText($install,[IO.File]::ReadAllText($Template),[Text.UTF8Encoding]::new($true))
  foreach($name in @('supervisor-task.ps1','update-common.ps1','install-preflight.ps1')){[IO.File]::WriteAllText((Join-Path $global:manualInstallFixture ('runtime\'+$name)),$fixtureModule,[Text.UTF8Encoding]::new($false))}
  [IO.File]::WriteAllText((Join-Path $global:manualInstallFixture 'codex.cmd'),"@exit /b 0`r`n",[Text.UTF8Encoding]::new($false))
  $check=(& $install -CheckOnly)|ConvertFrom-Json
  Assert ($check.ok -and $check.startupMode-eq 'manual') 'CheckOnly must report the manual edition'
  Assert ($global:manualInstallCalls.Count-eq 1 -and $global:manualInstallCalls[0]-eq 'preflight') 'CheckOnly must not register, stop, or install anything'
  Assert (!(Test-Path -LiteralPath (Join-Path $global:manualInstallFixture 'installation.json'))) 'CheckOnly must not create installation state'
  $global:manualInstallCalls.Clear()
  & $install|Out-Null
  $saved=Get-Content -LiteralPath (Join-Path $global:manualInstallFixture 'installation.json') -Raw -Encoding UTF8|ConvertFrom-Json
  Assert ($saved.startupMode-eq 'manual') 'Installation must persist its edition'
  $preferences=Get-Content -LiteralPath (Join-Path $saved.dataDir 'update-preferences.json') -Raw -Encoding UTF8|ConvertFrom-Json
  Assert ($preferences.automatic-eq $false) 'Manual installation must disable automatic updates'
  Assert (!(Test-Path -LiteralPath $saved.startupShortcut)) 'Manual installation must not create a startup shortcut'
  Assert ($global:manualInstallCalls.Contains('remove-task') -and $global:manualInstallCalls.Contains('verify-plugin')) 'Manual installation must remove its prior task and still verify the plugin'
  Assert ($global:manualInstallCalls[$global:manualInstallCalls.Count-1]-eq 'unlock') 'Installation must release its lock'
  $agent=Join-Path $global:manualInstallFixture 'agent';$null=New-Item -ItemType Directory -Path $agent -Force
  [IO.File]::WriteAllText((Join-Path $agent 'update-transaction.json'),'{"phase":"registering"}')
  $global:manualInstallCalls.Clear();$blocked=$false
  try{& $install|Out-Null}catch{if($_.Exception.Message-notlike 'Recover the unfinished update*'){throw};$blocked=$true}
  Assert ($blocked -and !$global:manualInstallCalls.Contains('stop-gui')) 'Unfinished updates must be rejected before stopping the GUI'
  Assert ($global:manualInstallCalls[$global:manualInstallCalls.Count-1]-eq 'unlock') 'A rejected installation must also release its lock'

  . ([scriptblock]::Create($fixtureModule))
  . ([scriptblock]::Create([IO.File]::ReadAllText($Updater,[Text.Encoding]::UTF8)))
  $script:config=@{startupMode='manual'};$script:dataDir=$saved.dataDir
  $script:settingsMenuUi=@{UpdateVersion=@{};AutoUpdate=@{};UpdateStatus=@{Header=@{}}}
  Write-WidgetSupervisorJson (Join-Path $script:dataDir 'update-preferences.json') @{automatic=$true}
  Initialize-WidgetUpdater
  Assert (!$script:autoUpdate) 'A manual edition must ignore a previously enabled update preference'
  Start-WidgetUpdate 'manual'
  $updateState=Read-WidgetUpdateJson (Join-Path $script:dataDir 'update-status.json')
  Assert ($updateState.phase-eq 'manual' -and !$script:updateProcess) 'The manual update action must explain manual updates without spawning an installer'
  Set-WidgetAutomaticUpdate $true
  Assert (!$script:autoUpdate -and !$script:settingsMenuUi.AutoUpdate.IsEnabled) 'The UI must not re-enable automatic updates for a manual edition'
  $script:config=@{}
  Write-WidgetSupervisorJson (Join-Path $script:dataDir 'update-preferences.json') @{automatic=$true}
  Initialize-WidgetUpdater
  Assert $script:autoUpdate 'The automatic edition must retain its original update preference behavior'
  Write-Output ("PASS: $checks isolated manual installer and updater assertions")
}finally{
  $resolved=[IO.Path]::GetFullPath($global:manualInstallFixture)
  $tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
  if(!$resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved)-notlike 'gpt-niang-manual-install-*'){throw 'Unexpected fixture cleanup path'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
