param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
$appDir=Split-Path $TestRoot -Parent
. (Join-Path $appDir 'runtime\completion-notifications.ps1')
function Assert($condition,[string]$message){if(!$condition){throw $message}}
function Save-Settings {}
function Reset-WidgetAutoQuoteSchedule {}
$script:appDir=$appDir;$script:collapsed=$true;$script:bubbleMode='quota'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-completion-pipe-'+[Guid]::NewGuid().ToString('N'))
$sessions=Join-Path $fixture 'sessions';$null=[IO.Directory]::CreateDirectory($sessions)
$file=Join-Path $sessions 'pipe.jsonl'
$node=(Get-Command node -ErrorAction Stop).Source
$script:config=@{nodePath=$node;codexHome=$fixture}
function Add-Event([string]$Id){
  $record=@{type='event_msg';timestamp=[DateTime]::UtcNow.ToString('o');payload=@{type='task_complete';turn_id=$Id}}
  [IO.File]::AppendAllText($file,(($record|ConvertTo-Json -Compress -Depth 4)+"`n"),[Text.UTF8Encoding]::new($false))
}
function Wait-Event {
  $before=$script:completionReceived;$deadline=[DateTime]::UtcNow.AddSeconds(8)
  do{Read-CompletionMonitorOutput;if($script:completionReceived-gt $before){return};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow-lt $deadline)
  throw 'The isolated completion monitor did not deliver a new event'
}
try{
  & $node --test (Join-Path $TestRoot 'completion-monitor.test.mjs')
  if($LASTEXITCODE-ne 0){throw 'Completion monitor Node tests failed'}
  [IO.File]::WriteAllText($file,((@{type='session_meta';payload=@{source='vscode'}}|ConvertTo-Json -Compress -Depth 4)+"`n"),[Text.UTF8Encoding]::new($false))
  Add-Event 'history'
  Initialize-CompletionNotificationState $null;Start-CompletionMonitor
  Assert (!$script:completionProcess) 'Disabled reminder must not start a process'
  Set-CompletionNotificationEnabled $true
  Assert ($script:completionProcess -and !$script:completionProcess.HasExited) 'Enabling starts one hidden monitor'
  $firstPid=$script:completionProcess.Id;Start-CompletionMonitor
  Assert ($script:completionProcess.Id-eq $firstPid) 'Repeated start cannot create another monitor'
  Start-Sleep -Milliseconds 1200;Read-CompletionMonitorOutput
  Assert (!$script:completionPending) 'Startup must baseline old endings'
  Add-Event 'first';Wait-Event
  Assert $script:completionPending 'Real UTF8 pipe sets one pending marker'
  Set-CompletionNotificationEnabled $false
  Assert (!$script:completionProcess -and !$script:completionPending) 'Disable stops and clears the monitor'
  Assert (!(Get-Process -Id $firstPid -ErrorAction SilentlyContinue)) 'Closed stdin releases the actual Node child'
  Add-Event 'while-off';Set-CompletionNotificationEnabled $true
  Start-Sleep -Milliseconds 1200;Read-CompletionMonitorOutput
  Assert (!$script:completionPending) 'Re-enable does not replay disabled events'
  Add-Event 'second';Wait-Event
  $currentPid=$script:completionProcess.Id;$script:completionProcess.Kill();$null=$script:completionProcess.WaitForExit(500)
  $script:completionRetryAfter=0;Start-CompletionMonitor
  Assert ($script:completionProcess.Id-ne $currentPid -and !$script:completionProcess.HasExited) 'Crashed monitor restarts alone'
  Start-Sleep -Milliseconds 1200
  $script:completionPending=$false;$script:completionReceived=0
  for($i=0;$i-lt 200;$i++){Add-Event ('burst-'+$i)}
  Start-Sleep -Milliseconds 1500;Read-CompletionMonitorOutput
  Assert ($script:completionPending -and $script:completionReceived-gt 0 -and $script:completionReceived-le 64) 'A burst is bounded and coalesces to one pending state'
  Set-CompletionNotificationEnabled $false
  $script:config.nodePath=Join-Path $fixture 'missing-node.exe'
  Set-CompletionNotificationEnabled $true
  Assert (!$script:completionProcess -and $script:completionLastError) 'Start failure is contained with a retry deadline'
  $retry=$script:completionRetryAfter;Start-CompletionMonitor
  Assert ($script:completionRetryAfter-eq $retry) 'Failure retries do not spin on every tick'
  Write-Output 'PASS: real child pipe, disabled baseline, one process, EOF cleanup, re-enable, crash recovery, bounded burst and contained startup failure'
}finally{
  Stop-CompletionMonitor;Clear-CompletionNotifications
  $resolved=[IO.Path]::GetFullPath($fixture);$allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
  if(!$resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved)-notlike 'gpt-niang-completion-pipe-*'){throw 'Unsafe completion pipe cleanup path'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
