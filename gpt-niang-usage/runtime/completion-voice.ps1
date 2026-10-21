# Fixed original character blips for "任务完成". Independent of click/bubble switches.
$script:completionVoice=$null
$script:completionVoiceSeen=[Collections.Generic.HashSet[string]]::new()
$script:completionVoiceOrder=[Collections.Generic.Queue[string]]::new()
function Get-CompletionVoicePreference($Settings) {
  if($null-eq $Settings -or $null-eq $Settings.taskCompletionVoice){return $true}
  return ($Settings.taskCompletionVoice -eq $true)
}
function Initialize-CompletionVoice {
  param([string]$AppDir)
  Close-CompletionVoice
  try{
    $path=Join-Path $AppDir 'assets\task-complete.wav'
    $sound=New-WidgetScaledSoundPlayer $path 1.0
    $script:completionVoice=[pscustomobject]@{Sound=$sound;Duration=(Get-WidgetWaveSeconds $path);BusyUntil=0L;Played=0;LastError=$null}
  }catch{$script:completionVoice=$null}
}
function Test-CompletionVoiceBusy {
  return ($null-ne $script:completionVoice -and [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()-lt $script:completionVoice.BusyUntil)
}
function Stop-CompletionVoice {
  if($script:completionVoice){
    if(Test-CompletionVoiceBusy){try{$script:completionVoice.Sound.Player.Stop()}catch{}}
    $script:completionVoice.BusyUntil=0L
  }
}
function Close-CompletionVoice {
  if($script:completionVoice){
    Stop-CompletionVoice
    Close-WidgetSoundPlayer $script:completionVoice.Sound.Player $script:completionVoice.Sound.Stream
    $script:completionVoice=$null
  }
}
function Set-CompletionVoiceEnabled([bool]$Enabled) {
  $script:completionVoiceEnabled=$Enabled
  if(!$Enabled){Stop-CompletionVoice}
  Update-CompletionMonitor
  Save-Settings
}
function Invoke-CompletionVoiceAudio { $script:completionVoice.Sound.Player.Play() }
function Request-CompletionVoice {
  param($Notification,[bool]$Visible)
  if($Notification.success-isnot [bool] -or !$Notification.success -or $Notification.eventType-notin @('task_complete','turn_complete','turn_completed')){return}
  # Record even when muted/hidden: re-enabling must not replay an old completion.
  if($Notification.turnId){
    $key=[string]$Notification.sessionId+'|'+[string]$Notification.turnId
    if(!$script:completionVoiceSeen.Add($key)){return}
    $script:completionVoiceOrder.Enqueue($key)
    while($script:completionVoiceOrder.Count-gt 128){$null=$script:completionVoiceSeen.Remove($script:completionVoiceOrder.Dequeue())}
  }
  if(!$script:completionVoiceEnabled -or !$Visible -or !$script:completionVoice -or (Test-CompletionVoiceBusy)){return}
  try{
    # Completion has priority over click sounds; simultaneous completions coalesce.
    if(Get-Command Stop-QuoteVoice -ErrorAction SilentlyContinue){Stop-QuoteVoice}
    Stop-WidgetAudio
    Invoke-CompletionVoiceAudio
    $script:completionVoice.BusyUntil=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()+[long]($script:completionVoice.Duration*1000)+60
    $script:completionVoice.Played++
    $script:completionVoice.LastError=$null
  }catch{$script:completionVoice.LastError=$_.Exception.Message}
}
