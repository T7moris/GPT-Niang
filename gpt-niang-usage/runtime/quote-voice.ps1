# Dynamic original quote blips. Text goes through stdin, never command arguments.
$script:quoteVoiceProcess=$null;$script:quoteVoiceSound=$null;$script:quoteVoiceStarted=0L
$script:quoteVoiceBusyUntil=0L;$script:quoteVoiceError=$null;$script:quoteVoiceTimer=$null
function Initialize-QuoteVoice {
  $script:quoteVoiceTimer=New-Object Windows.Threading.DispatcherTimer
  $script:quoteVoiceTimer.Interval=[TimeSpan]::FromMilliseconds(40)
  $script:quoteVoiceTimer.Add_Tick({Pump-QuoteVoice ([bool]$script:window.IsVisible)})
}
function Get-QuoteVoicePreference($Settings){
  if($null-eq $Settings -or $null-eq $Settings.quoteVoice){return $true}
  return ($Settings.quoteVoice-eq $true)
}
function Test-QuoteVoiceBusy {return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()-lt $script:quoteVoiceBusyUntil}
function Stop-QuoteVoice {
  if($script:quoteVoiceTimer){$script:quoteVoiceTimer.Stop()}
  if($script:quoteVoiceProcess){
    try{if(!$script:quoteVoiceProcess.HasExited){$script:quoteVoiceProcess.Kill();$null=$script:quoteVoiceProcess.WaitForExit(1000)}}catch{}
    try{$script:quoteVoiceProcess.Dispose()}catch{};$script:quoteVoiceProcess=$null
  }
  if($script:quoteVoiceSound){Close-WidgetSoundPlayer $script:quoteVoiceSound.Player $script:quoteVoiceSound.Stream;$script:quoteVoiceSound=$null}
  $script:quoteVoiceBusyUntil=0L
}
function Set-QuoteVoiceEnabled([bool]$Enabled){
  $script:quoteVoiceEnabled=$Enabled
  if(!$Enabled){Stop-QuoteVoice}
  Save-Settings
}
function Request-QuoteVoice([string]$Text){
  Stop-QuoteVoice
  if(!$script:quoteVoiceEnabled -or $script:collapsed -or $script:bubbleMode-ne 'quote' -or !$script:window.IsVisible -or (Test-CompletionVoiceBusy) -or [string]::IsNullOrWhiteSpace($Text)){return}
  $process=$null
  try{
    if($Text.Length-gt 400){throw 'Quote too long'}
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$script:config.nodePath
    $cache=Join-Path $script:dataDir 'quote-voice-cache'
    $start.Arguments='"'+(Join-Path $script:appDir 'runtime\quote-voice.mjs')+'" "'+$cache+'"'
    $start.WorkingDirectory=$script:appDir;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
    $process=New-Object Diagnostics.Process;$process.StartInfo=$start
    if(!$process.Start()){throw 'Quote voice did not start'}
    $inputBytes=[Text.UTF8Encoding]::new($false).GetBytes((@{text=$Text}|ConvertTo-Json -Compress))
    $process.StandardInput.BaseStream.Write($inputBytes,0,$inputBytes.Length)
    $process.StandardInput.BaseStream.Flush()
    $process.StandardInput.Close()
    $script:quoteVoiceProcess=$process;$script:quoteVoiceStarted=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();$script:quoteVoiceError=$null
    if($script:quoteVoiceTimer){$script:quoteVoiceTimer.Start()}
  }catch{if($process){try{if(!$process.HasExited){$process.Kill()};$process.Dispose()}catch{}};$script:quoteVoiceError='Quote voice could not start'}
}
function Invoke-QuoteVoiceAudio {$script:quoteVoiceSound.Player.Play()}
function Pump-QuoteVoice([bool]$Visible){
  if(!$Visible -or !$script:quoteVoiceEnabled -or $script:collapsed -or $script:bubbleMode-ne 'quote'){Stop-QuoteVoice;return}
  if(!$script:quoteVoiceProcess){return}
  $process=$script:quoteVoiceProcess
  try{
    if(!$process.HasExited){
      if([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()-$script:quoteVoiceStarted-gt 8000){Stop-QuoteVoice;$script:quoteVoiceError='Quote voice timed out'}
      return
    }
    if($process.ExitCode-ne 0){throw 'Quote renderer failed'}
    $result=$process.StandardOutput.ReadToEnd()|ConvertFrom-Json
    $root=[IO.Path]::GetFullPath((Join-Path $script:dataDir 'quote-voice-cache')).TrimEnd('\')+'\'
    $file=[IO.Path]::GetFullPath([string]$result.file)
    if(!$file.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($file)-notmatch '^[a-f0-9]{64}\.wav$'){throw 'Invalid quote asset'}
    if(!(Test-CompletionVoiceBusy)){
      Stop-WidgetAudio
      $script:quoteVoiceSound=New-WidgetScaledSoundPlayer $file 1.0
      Invoke-QuoteVoiceAudio
      $script:quoteVoiceBusyUntil=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()+[long]((Get-WidgetWaveSeconds $file)*1000)+60
      # A long quote may outlast the normal five-second bubble. Quota TTL is untouched.
      $script:sceneDeadline=[Math]::Max($script:sceneDeadline,$script:quoteVoiceBusyUntil+200)
    }
  }catch{$script:quoteVoiceError='Quote voice could not play'}
  finally{if($script:quoteVoiceProcess -eq $process -and $process.HasExited){$process.Dispose();$script:quoteVoiceProcess=$null;if($script:quoteVoiceTimer){$script:quoteVoiceTimer.Stop()}}}
}
