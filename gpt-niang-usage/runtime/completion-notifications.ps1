if(!('GptCompletionMonitorOutput' -as [type])){
  Add-Type -TypeDefinition @'
using System.Diagnostics;
using System.Collections.Concurrent;

public static class GptCompletionMonitorOutput {
  private static readonly ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
  public static void Attach(Process process) {
    process.OutputDataReceived += (sender, args) => {
      if(args.Data != null) Lines.Enqueue(args.Data);
    };
    process.ErrorDataReceived += (sender, args) => { };
  }
  public static bool TryRead(out string line) { return Lines.TryDequeue(out line); }
  public static void Clear() { string line; while(Lines.TryDequeue(out line)) { } }
}
'@
}

function Initialize-CompletionNotificationState {
  $script:completionQueue=[Collections.Generic.Queue[string]]::new()
  $script:completionPendingMessage=$null
  $script:completionActiveMessage=$null
  $script:completionProcess=$null
  $script:completionRetryAfter=0
  if($null-eq $script:completionNotificationsEnabled){$script:completionNotificationsEnabled=$true}
}

function Get-CompletionNotificationPreference($Settings) {
  if($null-eq $Settings -or $null-eq $Settings.taskCompletionBubble){return $true}
  return [bool]$Settings.taskCompletionBubble
}

function Clear-CompletionNotifications {
  if($script:completionQueue){$script:completionQueue.Clear()}
  $script:completionPendingMessage=$null
  $script:completionActiveMessage=$null
  [GptCompletionMonitorOutput]::Clear()
}

function Clear-CompletionNotificationQueue {
  if($script:completionQueue){$script:completionQueue.Clear()}
  $script:completionPendingMessage=$null
  $script:completionActiveMessage=$null
}

function Test-CompletionMonitorNeeded {
  if($script:completionNotificationsEnabled -or $script:completionVoiceEnabled){return $true}
  return ($script:characterMode-eq 'pixel' -and (Get-Command Get-WidgetCharacterActionAvailable -ErrorAction SilentlyContinue) -and ((Get-WidgetCharacterActionAvailable 'complete') -or (Get-WidgetCharacterActionAvailable 'working')))
}

function Update-CompletionMonitor {
  if(Test-CompletionMonitorNeeded){Start-CompletionMonitor}
  else{Stop-CompletionMonitor}
}

function Start-CompletionMonitor {
  if(!(Test-CompletionMonitorNeeded)){return}
  if($script:completionProcess){
    try{if(!$script:completionProcess.HasExited){return}}catch{}
    try{$script:completionProcess.Dispose()}catch{}
    $script:completionProcess=$null
  }
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  if($now-lt $script:completionRetryAfter){return}
  [GptCompletionMonitorOutput]::Clear()
  $process=$null
  try{
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=[string]$script:config.nodePath
    $start.Arguments='"'+(Join-Path $script:appDir 'runtime\completion-monitor.mjs')+'"'
    $start.WorkingDirectory=$script:appDir
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$start
    [GptCompletionMonitorOutput]::Attach($process)
    if(!$process.Start()){throw 'Node.js did not start the completion monitor.'}
    $process.BeginOutputReadLine();$process.BeginErrorReadLine()
    $script:completionProcess=$process
    $script:completionRetryAfter=$now+5000
  }catch{
    if($process){try{$process.Dispose()}catch{}}
    $script:completionProcess=$null
    $script:completionRetryAfter=$now+5000
  }
}

function Stop-CompletionMonitor {
  if($script:completionProcess){
    try{
      if(!$script:completionProcess.HasExited){
        $script:completionProcess.Kill()
        $null=$script:completionProcess.WaitForExit(1500)
      }
    }catch{}
    try{$script:completionProcess.Dispose()}catch{}
    $script:completionProcess=$null
  }
  [GptCompletionMonitorOutput]::Clear()
  if(Get-Command Set-WidgetCharacterWorking -ErrorAction SilentlyContinue){Set-WidgetCharacterWorking $false}
}

function Set-CompletionNotificationEnabled([bool]$Enabled) {
  $script:completionRetryAfter=0
  $script:completionNotificationsEnabled=$Enabled
  if(!$Enabled){
    Clear-CompletionNotificationQueue
    if(!$script:collapsed -and $script:bubbleMode-eq 'completion'){
      $script:completionActiveMessage=$null
      Hide-Quota
    }
  }
  Update-CompletionMonitor
  Save-Settings
}

function Queue-CompletionNotification {
  param([string]$Message,[bool]$Visible)
  if(!$script:completionNotificationsEnabled -or [string]::IsNullOrWhiteSpace($Message)){return}
  if(!$Visible){
    while($script:completionQueue.Count-gt 0){$script:completionPendingMessage=$script:completionQueue.Dequeue()}
    $script:completionPendingMessage=$Message
    return
  }
  if($script:completionPendingMessage){$script:completionQueue.Enqueue($script:completionPendingMessage);$script:completionPendingMessage=$null}
  $script:completionQueue.Enqueue($Message)
}

function Receive-CompletionMonitorLine {
  param([string]$Line,[bool]$Visible)
  try{
    $result=$Line|ConvertFrom-Json
    if($result.eventType-eq 'work_state'){
      if($result.working-is [bool] -and (Get-Command Set-WidgetCharacterWorking -ErrorAction SilentlyContinue)){Set-WidgetCharacterWorking ([bool]$result.working)}
      return
    }
    if(Get-Command Request-CompletionVoice -ErrorAction SilentlyContinue){Request-CompletionVoice -Notification $result -Visible $Visible}
    if($result.success -eq $true -and (Get-Command Request-WidgetCharacterAction -ErrorAction SilentlyContinue)){Request-WidgetCharacterAction 'complete' -Success $true|Out-Null}
    if($script:completionNotificationsEnabled -and $result.message-is [string]){Queue-CompletionNotification -Message ([string]$result.message) -Visible $Visible}
  }catch{}
}

function Read-CompletionMonitorOutput([bool]$Visible) {
  $line=$null
  while([GptCompletionMonitorOutput]::TryRead([ref]$line)){
    Receive-CompletionMonitorLine -Line $line -Visible $Visible
    $line=$null
  }
}

function Pump-CompletionNotifications([bool]$Visible) {
  Update-CompletionMonitor
  Read-CompletionMonitorOutput $Visible
  if(!$script:completionNotificationsEnabled){return}
  if(!$Visible){
    while($script:completionQueue.Count-gt 0){$script:completionPendingMessage=$script:completionQueue.Dequeue()}
    return
  }
  if($script:completionPendingMessage){$script:completionQueue.Enqueue($script:completionPendingMessage);$script:completionPendingMessage=$null}
  if($script:completionQueue.Count-eq 0){
    return
  }
  if(!$script:collapsed -and $script:bubbleMode-eq 'completion'){return}
  if($script:closeTimer -and $script:closeTimer.IsEnabled){return}
  $message=$script:completionQueue.Dequeue()
  Show-CompletionBubble $message
}
