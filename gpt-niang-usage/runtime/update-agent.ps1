param([switch]$Supervisor)
$ErrorActionPreference='Stop'
try {
  . (Join-Path $PSScriptRoot 'supervisor-task.ps1')
  . (Join-Path $PSScriptRoot 'update-common.ps1')
  $binding=Read-WidgetUpdateJson (Join-Path $PSScriptRoot 'binding.json')
  $null=Assert-WidgetUpdateBinding $binding.appDir $binding.dataDir $PSScriptRoot
  $journal=Read-WidgetUpdateJson (Join-Path $PSScriptRoot 'update-transaction.json')
  if($journal -and $journal.phase-notin @('committed','rolled-back')) {
    if($journal.phase-eq 'recovery-failed'){throw 'Update recovery failed previously. Keep the backups and inspect update-diagnostic.txt.'}
    $owner=Read-WidgetUpdateJson (Join-Path $PSScriptRoot 'update.lock\owner.json')
    $helperAlive=$owner.helperPid -and (Get-Process -Id ([int]$owner.helperPid) -ErrorAction SilentlyContinue)
    if($helperAlive){if(!$Supervisor -or $journal.phase-notin @('registering','registering-old')){return}}
    else {& (Join-Path $PSScriptRoot 'update-helper.ps1') -Recover}
  }
  if($Supervisor){& (Join-Path $binding.appDir 'runtime\supervisor.ps1')}
  else {& (Join-Path $binding.appDir 'runtime\start-supervisor.ps1')}
} catch {
  [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'update-diagnostic.txt'),$_.Exception.ToString(),[Text.UTF8Encoding]::new($false))
  exit 1
}
