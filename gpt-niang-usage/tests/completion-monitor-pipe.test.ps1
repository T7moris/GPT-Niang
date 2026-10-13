$ErrorActionPreference='Stop'
$appDir=Split-Path $PSScriptRoot -Parent
. (Join-Path $appDir 'runtime\completion-notifications.ps1')
function Assert-Equal($actual,$expected,[string]$message){if($actual-ne $expected){throw "$message : expected '$expected', got '$actual'"}}
function Save-Settings {}

$oldCodexHome=$env:CODEX_HOME
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-completion-pipe-'+[Guid]::NewGuid().ToString('N'))
$env:CODEX_HOME=Join-Path $testRoot '.codex'
$script:appDir=$appDir
$script:config=@{nodePath=(Get-Command node).Source}
$script:completionNotificationsEnabled=$true
Initialize-CompletionNotificationState
$sessionDir=Join-Path $env:CODEX_HOME 'sessions'
$rollout=Join-Path $sessionDir 'completion-pipe-test.jsonl'

function Add-TestCompletion([string]$TurnId,[string]$Message){
  $record=@{type='event_msg';payload=@{type='task_complete';turn_id=$TurnId;last_agent_message=$Message}}
  [IO.File]::AppendAllText($rollout,(($record|ConvertTo-Json -Compress -Depth 5)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
}
function Wait-ForCompletion([int]$TimeoutMs=7000){
  $deadline=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()+$TimeoutMs
  while([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()-lt $deadline){
    $line=$null
    if([GptCompletionMonitorOutput]::TryRead([ref]$line)){return $line}
    Start-Sleep -Milliseconds 100
  }
  return $null
}

try{
  $null=New-Item -ItemType Directory -Path $sessionDir -Force
  Start-CompletionMonitor
  Start-Sleep -Milliseconds 1200
  Add-TestCompletion 'before-disable' '首次完成'
  $line=Wait-ForCompletion
  if(!$line){
    $state=if($script:completionProcess){if($script:completionProcess.HasExited){'exited '+$script:completionProcess.ExitCode}else{'still running'}}else{'not started'}
    $exists=[IO.File]::Exists($rollout);$size=if($exists){(Get-Item -LiteralPath $rollout).Length}else{0}
    $arguments=if($script:completionProcess){$script:completionProcess.StartInfo.Arguments}else{''}
    $childHome=if($script:completionProcess){$script:completionProcess.StartInfo.EnvironmentVariables['CODEX_HOME']}else{''}
    throw ('The local Node monitor did not deliver a completion through its memory pipe ('+$state+'; file='+$exists+'/'+$size+'; args='+$arguments+'; home='+$childHome+').')
  }
  Receive-CompletionMonitorLine -Line $line -Visible $true
  Assert-Equal $script:completionQueue.Dequeue() 'Codex 已完成：首次完成' 'Pipe preserves the completion message'

  Set-CompletionNotificationEnabled $false
  Add-TestCompletion 'while-disabled' '关闭期间完成'
  Set-CompletionNotificationEnabled $true
  Start-Sleep -Milliseconds 1200
  $line=$null
  if([GptCompletionMonitorOutput]::TryRead([ref]$line)){throw 'Re-enabling replayed an old completion event.'}
  Assert-Equal $script:completionQueue.Count 0 'Re-enabling baselines existing events instead of replaying them'

  Add-TestCompletion 'after-reenable' '重新开启后完成'
  $line=Wait-ForCompletion
  if(!$line){throw 'The re-enabled local monitor did not receive a new completion.'}
  Receive-CompletionMonitorLine -Line $line -Visible $true
  Assert-Equal $script:completionQueue.Dequeue() 'Codex 已完成：重新开启后完成' 'Re-enabled monitor receives future completions'
  Write-Output 'PASS: Windows process pipe delivers new events, disable stops monitoring and re-enable skips old events'
}finally{
  Set-CompletionNotificationEnabled $false
  if($null-eq $oldCodexHome){Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue}else{$env:CODEX_HOME=$oldCodexHome}
  if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
