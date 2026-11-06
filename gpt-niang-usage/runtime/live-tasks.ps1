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
    $start.Arguments+=' --phrases-file "'+(Join-Path $script:dataDir 'task-dialogue.user.json')+'"'
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

$script:taskGroupNames=[ordered]@{
  work='刚开始／处理中';tool='正在使用工具';think='想了有一会儿';long='还在忙（长任务）';wait='等你回复'
  reply='正在写回复';fast='很快完成';done='普通完成';longDone='长任务完成';stopped='已停止／中断'
}
function ConvertTo-TaskEditorLines($Quotes){
  return (@(foreach($quote in $Quotes){([string]$quote) -replace '\r?\n',' | '}) -join [Environment]::NewLine)
}
function Read-TaskEditorLines([string]$Value,[string]$Group){
  $name=$script:taskGroupNames[$Group]
  $unique=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $face=[Windows.Media.Typeface]::new([Windows.Media.FontFamily]::new('Microsoft YaHei UI'),[Windows.FontStyles]::Normal,[Windows.FontWeights]::Bold,[Windows.FontStretches]::Normal)
  $lineNo=0
  foreach($raw in ($Value -split '\r?\n')){
    $lineNo++;if(!$raw.Trim()){continue}
    $parts=@(($raw -split '[|｜]') | ForEach-Object {$_.Trim()})
    if($parts.Count -gt 3 -or $parts -contains ''){throw "「$name」第 $lineNo 句：每句最多三行，换行符两边都要有字。"}
    foreach($part in $parts){
      $m=[Windows.Media.FormattedText]::new($part,[Globalization.CultureInfo]::CurrentCulture,[Windows.FlowDirection]::LeftToRight,$face,15,[Windows.Media.Brushes]::Black)
      if($m.WidthIncludingTrailingWhitespace -gt 188){throw "「$name」第 $lineNo 句太长，请用 | 分行，或缩短这一句。"}
    }
    $quote=$parts -join "`n"
    if($unique.Add($quote)){$quote}
  }
  if(!$unique.Count){throw "「$name」至少留一句，也可以点「恢复本组内置」。"}
  if($unique.Count -gt 200){throw "「$name」每组最多保存 200 句。"}
}
function Save-TaskEditor {
  $script:taskDraft[$script:taskEditingGroup]=$script:taskEditor.FindName('Lines').Text
  $groups=@{}
  foreach($key in $script:taskGroupNames.Keys){
    $lines=@(Read-TaskEditorLines $script:taskDraft[$key] $key)
    $defaults=@($script:taskDefaults.$key)
    if(($defaults -join [char]0) -cne ($lines -join [char]0)){$groups[$key]=[string[]]$lines}
  }
  Write-WidgetJson $script:taskCustomFile @{version=1;groups=$groups}
  $script:taskSavedDraft=$script:taskDraft.Clone()
  $script:taskEditor.FindName('Feedback').Text='已保存。挂件会自动读取新台词。'
}
function Open-TaskEditor {
  if($script:taskEditor -and $script:taskEditor.IsVisible){$script:taskEditor.Activate()|Out-Null;return}
  $w=[Windows.Markup.XamlReader]::Parse(@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="GPT 娘 · 任务台词" Width="590" Height="490" MinWidth="465" MinHeight="330" ShowInTaskbar="False" WindowStartupLocation="CenterScreen" FontFamily="Microsoft YaHei UI" FontSize="14" Background="#FAF8FD">
  <Grid Margin="20">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <ComboBox x:Name="Group" Width="235" HorizontalAlignment="Left" Padding="7,4"/>
    <TextBlock Grid.Row="1" Margin="0,12,0,8" Text="每行一句，长句用 | 指定气泡里的换行。保存会应用所有分组的修改。" Foreground="#745A98" TextWrapping="Wrap"/>
    <TextBox x:Name="Lines" Grid.Row="2" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Padding="10" FontSize="15" BorderBrush="#BBAACA"/>
    <TextBlock x:Name="Feedback" Grid.Row="3" Margin="0,8" Foreground="#745A98" TextWrapping="Wrap"/>
    <Grid Grid.Row="4">
      <Button x:Name="Defaults" Content="恢复本组内置" Padding="10,5" HorizontalAlignment="Left"/>
      <StackPanel HorizontalAlignment="Right" Orientation="Horizontal">
        <Button x:Name="Save" Content="保存" Padding="18,5" Margin="0,0,8,0"/>
        <Button x:Name="Done" Content="关闭" Padding="15,5"/>
      </StackPanel>
    </Grid>
  </Grid>
</Window>
'@)
  $script:taskDefaults=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $script:appDir 'assets\task-dialogue.defaults.json')))
  $script:taskCustomFile=Join-Path $script:dataDir 'task-dialogue.user.json'
  $script:taskDraft=@{}
  $script:taskEditingGroup=$null
  $script:taskEditor=$w
  $w.Owner=$script:window
  $custom=$null
  if([IO.File]::Exists($script:taskCustomFile)){
    try{
      $custom=ConvertFrom-Json ([IO.File]::ReadAllText($script:taskCustomFile))
      if($custom.version -ne 1 -or $null -eq $custom.groups){throw '未知文件格式'}
    }catch{
      $w.FindName('Feedback').Text='个人台词文件无法读取。为保护原文件，本次只能查看。'
      $w.FindName('Save').IsEnabled=$false
    }
  }
  foreach($key in $script:taskGroupNames.Keys){
    $values=$script:taskDefaults.$key
    if($custom -and $custom.groups.$key){$values=$custom.groups.$key}
    $script:taskDraft[$key]=ConvertTo-TaskEditorLines $values
    $option=[Windows.Controls.ComboBoxItem]::new()
    $option.Tag=$key;$option.Content=$script:taskGroupNames[$key]
    $null=$w.FindName('Group').Items.Add($option)
  }
  $script:taskSavedDraft=$script:taskDraft.Clone()
  $w.FindName('Group').Add_SelectionChanged({
    $lines=$script:taskEditor.FindName('Lines')
    if($script:taskEditingGroup){$script:taskDraft[$script:taskEditingGroup]=$lines.Text}
    $script:taskEditingGroup=$script:taskEditor.FindName('Group').SelectedItem.Tag
    $lines.Text=$script:taskDraft[$script:taskEditingGroup]
  })
  $w.FindName('Defaults').Add_Click({
    $key=$script:taskEditingGroup
    $script:taskEditor.FindName('Lines').Text=ConvertTo-TaskEditorLines $script:taskDefaults.$key
    $script:taskEditor.FindName('Feedback').Text='已载入本组内置台词，点「保存」后生效。'
  })
  $w.FindName('Save').Add_Click({try{Save-TaskEditor}catch{$script:taskEditor.FindName('Feedback').Text=$_.Exception.Message}})
  $w.FindName('Done').Add_Click({$script:taskEditor.Close()})
  $w.Add_Closing({param($sender,$args)
    if(!$sender.FindName('Save').IsEnabled -or !$script:taskEditingGroup){return}
    $script:taskDraft[$script:taskEditingGroup]=$sender.FindName('Lines').Text
    $dirty=@($script:taskGroupNames.Keys|Where-Object {$script:taskDraft[$_] -cne $script:taskSavedDraft[$_]})
    if(!$dirty.Count){return}
    $answer=[Windows.MessageBox]::Show($sender,'关闭前要保存修改过的任务台词吗？','任务台词','YesNoCancel','Question')
    if($answer -eq 'Cancel'){$args.Cancel=$true}
    elseif($answer -eq 'Yes'){try{Save-TaskEditor}catch{$sender.FindName('Feedback').Text=$_.Exception.Message;$args.Cancel=$true}}
  })
  $w.Add_Closed({$script:taskEditor=$null})
  $w.FindName('Group').SelectedIndex=3
  $w.Show()
}
