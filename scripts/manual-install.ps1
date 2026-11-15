param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
$appDir=$PSScriptRoot
. (Join-Path $appDir 'runtime\supervisor-task.ps1')
. (Join-Path $appDir 'runtime\update-common.ps1')
. (Join-Path $appDir 'runtime\install-preflight.ps1')
$config=Get-WidgetInstallPreflight -SourceDir $appDir -AppDir $appDir
if($CheckOnly){@{ok=$true;appDir=$appDir;startupMode='manual'}|ConvertTo-Json;return}
$lock=Enter-WidgetUpdateLock
try {
  $journal=Read-WidgetUpdateJson (Join-Path (Get-WidgetUpdateAgentDir) 'update-transaction.json')
  if($journal -and $journal.phase-notin @('committed','rolled-back')){throw 'Recover the unfinished update before installing.'}
  $null=New-Item -ItemType Directory -Path $config.dataDir -Force
  Stop-WidgetSupervisorTask -AppDir $appDir -Configuration $config
  Stop-WidgetGui -AppDir $appDir -DataDir $config.dataDir
  $config.startupMode='manual'
  Write-WidgetSupervisorJson (Join-Path $appDir 'installation.json') $config
  Unregister-WidgetSupervisorTask -AppDir $appDir
  if(Test-Path -LiteralPath $config.startupShortcut){
    $shortcut=(New-Object -ComObject WScript.Shell).CreateShortcut($config.startupShortcut)
    if(!(Test-WidgetStartupShortcutIdentity $shortcut $appDir)){throw 'Existing shortcut belongs to another installation.'}
    Remove-Item -LiteralPath $config.startupShortcut
  }
  Install-WidgetUpdateAgent $appDir $config.dataDir
  Write-WidgetSupervisorJson (Join-Path $appDir '.mcp.json') @{mcpServers=@{'gpt-niang-usage'=@{command=$config.nodePath;args=@((Join-Path $appDir 'runtime\mcp.mjs'))}}}
  Write-WidgetSupervisorJson (Join-Path $config.dataDir 'update-preferences.json') @{automatic=$false}
  Write-WidgetSupervisorJson (Join-Path $config.dataDir 'update-status.json') @{phase='manual';message='手动启动版请下载新的手动启动包更新。'}
  & $config.codexPath plugin marketplace add $config.marketplaceRoot --json
  if($LASTEXITCODE-ne 0){throw 'Codex rejected the local marketplace.'}
  & $config.codexPath plugin add 'gpt-niang-usage@gpt-niang-local' --json
  if($LASTEXITCODE-ne 0){throw 'Codex rejected the GPT Niang plugin.'}
  Assert-WidgetPluginRegistration $config.codexPath $config.version
  Write-Output ('GPT Niang '+$config.version+' installed for manual startup. Run the root open CMD to show the widget.')
} finally {Exit-WidgetUpdateLock $lock}
