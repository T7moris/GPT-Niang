$script:liveTasksEnabled=!(Test-Path -LiteralPath (Join-Path $script:dataDir 'live-tasks-off.flag'))
$script:liveCount=0
$script:liveShown=$false
$script:liveRetry=0L
$script:liveSeen=@{}
$script:liveEndUntil=0L
$script:liveEnd=$null

function Stop-LiveTasks {
  if($script:liveReader){
    try{
      $script:liveReader.StandardInput.Close()
      if(!$script:liveReader.WaitForExit(800)){$script:liveReader.Kill()}
    }catch{}finally{$script:liveReader.Dispose()}
  }
  $script:liveReader=$null
  $script:liveLine=$null
  $script:liveData=$null
  $script:liveCount=0
  $script:liveEnd=$null
}
function Set-LiveTasksEnabled([bool]$Enabled){
  $flag=Join-Path $script:dataDir 'live-tasks-off.flag'
  if($Enabled){if(Test-Path -LiteralPath $flag){[IO.File]::Delete($flag)}}
  else{[IO.File]::WriteAllText($flag,'off');Stop-LiveTasks}
  $script:liveTasksEnabled=$Enabled
  $script:liveRetry=0L
  Update-LiveTaskBadge ([bool]$script:window.IsVisible)
}
function Read-LiveTasks {
  if($script:liveReader -and $script:liveReader.HasExited){Stop-LiveTasks}
  if(!$script:liveReader){
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if($now-lt $script:liveRetry){return}
    $script:liveRetry=$now+5000
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$script:config.nodePath
    $start.Arguments='"'+(Join-Path $script:appDir 'runtime\live-tasks.mjs')+'"'
    $start.UseShellExecute=$false
    $start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true
    $start.RedirectStandardOutput=$true
    $start.StandardOutputEncoding=[Text.Encoding]::UTF8
    if($script:config.codexHome){$start.EnvironmentVariables['CODEX_HOME']=$script:config.codexHome}
    $script:liveReader=[Diagnostics.Process]::Start($start)
    $script:liveLine=$script:liveReader.StandardOutput.ReadLineAsync()
  }
  for($i=0;$i-lt 16 -and $script:liveLine.IsCompleted;$i++){
    $line=$script:liveLine.GetAwaiter().GetResult()
    if($null-eq $line){Stop-LiveTasks;return}
    $script:liveData=ConvertFrom-Json -InputObject $line
    $script:liveCount=[int]$script:liveData.count
    $script:liveLine=$script:liveReader.StandardOutput.ReadLineAsync()
  }
}
function Hide-LiveTaskBubble {
  $script:liveShown=$false
  $script:liveKind=$null
  $panel=$script:window.FindName('LiveTaskBadge')
  if($panel){$panel.Visibility='Collapsed'}
}
function Get-LiveTaskScene([long]$Now){
  foreach($key in @($script:liveSeen.Keys)){if($script:liveSeen[$key] -lt $Now-60000){$script:liveSeen.Remove($key)}}
  if($script:liveEnd -and $Now -lt $script:liveEndUntil){return $script:liveEnd}
  $script:liveEnd=$null
  foreach($event in @($script:liveData.ends | Sort-Object at)){
    if(!$event -or !$event.id -or $script:liveSeen.ContainsKey($event.id) -or $Now-[long]$event.at -gt 30000){continue}
    $script:liveSeen[$event.id]=$Now
    $script:liveEndUntil=$Now+6500
    $script:liveEnd=$event
    return $event
  }
  return $script:liveData.task
}
function Set-LiveDialogueText($Label,[string]$Value){
  if($Label.Tag -ceq $Value){return}
  $rows=@($Value -split '\r?\n')
  $face=[Windows.Media.Typeface]::new($Label.FontFamily,$Label.FontStyle,$Label.FontWeight,$Label.FontStretch)
  # Keep the outer lines inside the curved sides, also when a phrase has three rows.
  foreach($size in 32..15){
    $leading=[Math]::Round($size*1.16,1)
    if($rows.Count*$leading -gt 100){continue}
    $fits=$true
    for($i=0;$i -lt $rows.Count;$i++){
      $text=[Windows.Media.FormattedText]::new($rows[$i],[Globalization.CultureInfo]::CurrentCulture,[Windows.FlowDirection]::LeftToRight,$face,$size,$Label.Foreground)
      $distance=[Math]::Abs(($i-($rows.Count-1)/2.0)*$leading)+$size*0.52+2
      $safeWidth=236*[Math]::Sqrt([Math]::Max(0,1-[Math]::Pow($distance/69,2)))
      if($text.WidthIncludingTrailingWhitespace -gt [Math]::Min(224,$safeWidth)){$fits=$false;break}
    }
    if($fits){break}
  }
  # Leave breathing room between the reply, its heading and the task title.
  $size=[Math]::Round($size*0.85,1)
  $leading=[Math]::Round($size*1.16,1)
  $Label.FontSize=$size
  $Label.LineHeight=$leading
  $Label.Text=$Value
  $Label.Tag=$Value
}
function Update-LiveTaskBadge([bool]$Visible) {
  $badge=$script:window.FindName('LiveTaskBadge')
  if(!$badge){return}
  try{
    if($script:liveTasksEnabled){Read-LiveTasks}
    $busy=!$script:collapsed -or $script:settingsSizePreview -or $script:context.IsOpen -or ($script:closeTimer -and $script:closeTimer.IsEnabled)
    if(!$Visible -or !$script:liveTasksEnabled -or $busy){Hide-LiveTaskBubble;return}
    $scene=Get-LiveTaskScene ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    if(!$scene){Hide-LiveTaskBubble;return}
    $heading=[string]$scene.heading
    if(!$scene.id -and $script:liveCount -gt 1){$heading=('{0} 项任务 · {1}' -f $script:liveCount,$heading)}
    $script:window.FindName('LiveTaskHeading').Text=$heading
    Set-LiveDialogueText ($script:window.FindName('LiveTaskDialogue')) ([string]$scene.line)
    $script:window.FindName('LiveTaskTitles').Text=[string]$scene.title
    $script:liveKind=[string]$scene.kind
    $script:liveShown=$true
    $badge.Visibility='Visible'
  }catch{Hide-LiveTaskBubble;Stop-LiveTasks}
}
