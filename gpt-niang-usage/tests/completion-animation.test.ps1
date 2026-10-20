$ErrorActionPreference='Stop'
$script:characterMode='pixel'
$script:completionNotificationsEnabled=$false
$script:collapsed=$true;$script:bubbleMode='quota';$script:completionActiveMessage=$null
$script:requestedActions=0;$script:completionQueue=[Collections.Generic.Queue[string]]::new()
$script:completionPendingMessage=$null;$script:completionProcess=$null;$script:completionRetryAfter=0
$script:workSignals=[Collections.Generic.List[bool]]::new();$script:availableActions=@('complete')
. (Join-Path $PSScriptRoot '..\runtime\completion-notifications.ps1')
function Get-WidgetCharacterActionAvailable([string]$ActionId){return ($ActionId-in $script:availableActions)}
function Set-WidgetCharacterWorking([bool]$Working){$script:workSignals.Add($Working)}
function Request-WidgetCharacterAction([string]$ActionId,[bool]$Success){if($ActionId-eq 'complete' -and $Success){$script:requestedActions++}}
function Update-CompletionMonitor {}
function Save-Settings {}
function Assert($condition,[string]$message){if(!$condition){throw $message}}
try{
  Assert (Test-CompletionMonitorNeeded) 'Completion animation did not keep the monitor active with bubbles disabled'
  Receive-CompletionMonitorLine '{"message":"done","eventType":"turn_complete","success":true,"turnId":"ok"}' $true
  Assert ($script:requestedActions-eq 1 -and $script:completionQueue.Count-eq 0) 'Bubble-disabled success did not trigger only the action'
  Receive-CompletionMonitorLine '{"message":"failed","eventType":"task_complete","success":false,"turnId":"error"}' $true
  Assert ($script:requestedActions-eq 1 -and $script:completionQueue.Count-eq 0) 'Error turn triggered animation or text while bubbles were disabled'
  $script:completionNotificationsEnabled=$true
  Receive-CompletionMonitorLine '{"message":"failed","eventType":"task_complete","success":false,"turnId":"error"}' $true
  Assert ($script:requestedActions-eq 1 -and $script:completionQueue.Count-eq 0 -and !$script:completionPending) 'Failed turns must clear work without creating a successful-completion reminder'
  $script:completionNotificationsEnabled=$false;$script:characterMode='original'
  Assert (!(Test-CompletionMonitorNeeded)) 'Monitor remained needed without bubbles or a pixel completion action'
  $script:characterMode='pixel';$script:availableActions=@('working')
  Assert (Test-CompletionMonitorNeeded) 'Working action did not keep monitor active with bubbles disabled'
  Receive-CompletionMonitorLine '{"eventType":"work_state","working":true,"activeTurns":2}' $true
  Receive-CompletionMonitorLine '{"eventType":"work_state","working":false,"activeTurns":0}' $false
  Receive-CompletionMonitorLine '{"eventType":"work_state","working":"false"}' $true
  Assert ($script:workSignals.Count-eq 2 -and $script:workSignals[0] -and !$script:workSignals[1]) 'Work state parsing or malformed-state handling failed'
  Write-Output 'PASS: completion and working actions independent of bubble toggle; work signals and malformed input; failed turns do not create success reminders'
}finally{
  if($script:completionProcess){Stop-CompletionMonitor}
}
