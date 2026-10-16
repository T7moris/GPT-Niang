param([string]$AppDir=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'supervisor-task.ps1')

function Restart-Widget {
  param([string]$AppDir)
  $info=Get-WidgetSupervisorInfo $AppDir
  # Resolve/validate the installation before stopping anything; do not reinstall or
  # modify preferences. Stop the supervisor first to avoid racing its auto-recovery.
  $task=Get-WidgetSupervisorTask $info
  if(!$task){throw 'Supervisor task is not installed. Run Install.ps1 first.'}
  Stop-WidgetSupervisorTask $AppDir
  Stop-WidgetGui -AppDir $AppDir -DataDir $info.DataDir
  Start-WidgetSupervisorTask $AppDir
}
Restart-Widget $AppDir
Write-Output 'GPT Niang restarted. In window mode it appears when Codex is visible.'
