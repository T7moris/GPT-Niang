param([string]$TestRoot=$PSScriptRoot,[string]$PreviewDirectory)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$appDir=Split-Path $TestRoot -Parent
. (Join-Path $appDir 'runtime\quotes.ps1')
foreach($module in @('quote-layout.ps1','color-theme.ps1','update-ui.ps1','completion-notifications.ps1')){
  . ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path (Join-Path $appDir 'runtime') $module),[Text.Encoding]::UTF8)))
}
Initialize-WidgetQuoteLayouts $appDir
$source=[IO.File]::ReadAllText((Join-Path $appDir 'widget.ps1'),[Text.Encoding]::UTF8)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$ease=$ast.Find({param($node)$node-is [Management.Automation.Language.CommandAst] -and $node.GetCommandName()-eq 'Add-Type' -and $node.Extent.Text.Contains('class GptBezierEase')},$true)
. ([ScriptBlock]::Create($ease.Extent.Text))
foreach($name in @('Set-AnimatedValue','Animate-Value','Set-BubbleState','Get-WidgetLayoutScale','Set-WidgetIndependentLayout','Reset-Label','Format-ResetTime','Format-ResetDisplay','Get-QuotaWindowLabel','Get-QuotaRows','Set-ResetTimeMode','Restart-SceneTtl','Tick-Scene','Apply-Scene','Update-BubbleTooltip','Switch-Scene','Show-Quote','Show-Quota','Open-WidgetBubble','Hide-Quota','Tick-WidgetAutoQuote','Write-WidgetJson','Save-Settings','Read-DisplayRequest','Request-Refresh','Next-Bubble','Click-Character')){
  $definition=$ast.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq $name},$true)
  if(!$definition){throw ('Missing real widget function: '+$name)}
  . ([ScriptBlock]::Create($definition.Extent.Text))
}
$script:checks=0
function Assert($condition,[string]$message){$script:checks++;if(!$condition){throw $message}}
function Drain-Wpf([int]$Milliseconds){
  $script:drainFrame=[Windows.Threading.DispatcherFrame]::new()
  $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds($Milliseconds)
  $timer.Add_Tick({param($sender,$event)$sender.Stop();$script:drainFrame.Continue=$false})
  $timer.Start();[Windows.Threading.Dispatcher]::PushFrame($script:drainFrame)
}
function Tick-ToBeforeDeadline([long]$Start,[long]$Deadline){
  for($point=$Start;$point-lt $Deadline;$point+=1000){Assert (!(Test-WidgetAutoQuoteDue $point $true $false)) 'A quote fired before a complete quiet interval'}
}
$script:dataDir=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-completion-wpf-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($script:dataDir)
$settingsFile=Join-Path $script:dataDir 'settings.json'
$refreshFile=Join-Path $script:dataDir 'refresh.flag'
$script:window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $appDir 'widget.xaml'),[Text.Encoding]::UTF8))
$script:ui=@{}
foreach($name in @('Root','Bubble','Tail','TailNear','SceneText','QuotaText','QuoteText','BubbleShape','Girl','PressScale','FacingScale','TextFacingScale','Header','Refresh','MenuButton','Status','LiveDot','ShortRow','WeekRow','ShortLabel','WeekLabel','ShortUsed','ShortLeft','ShortReset','ShortBar','WeekUsed','WeekLeft','WeekReset','WeekBar')){$script:ui[$name]=$script:window.FindName($name)}
$script:ui.Girl.Source=[Windows.Media.Imaging.BitmapImage]::new([Uri](Join-Path $appDir 'assets\gpt-dragon-niang-bust.png'))
$script:status=@{windows=@()};$script:collapsed=$true;$script:bubbleMode='quota';$script:bubbleEpoch=0;$script:sceneRevision=0
$script:sceneStartedAt=0;$script:sceneDeadline=0;$script:sceneTimer=$null;$script:resetPhaseTimer=$null;$script:closeTimer=$null
$script:resetTimeMode='countdown';$script:drag=$null;$script:context=@{IsOpen=$false};$script:settingsSizePreview=$false
$script:quoteEditor=$null;$script:colorTriggerEditor=$null;$script:characterGallery=$null;$script:widgetColors=$null
$script:scale=0.6;$script:bubbleScale=1.0;$script:displayScale=1.0;$script:offsetRight=781.6;$script:offsetLeft=54.4;$script:offsetBottom=87.2
$script:characterId='gpt-dragon';$script:anchor='free';$script:side='left';$script:soundOn=$false;$script:soundVolume=0.37
$script:bubbleTapAdvance=$true;$script:hideMenu=$true;$script:followHost=$true;$script:desktopTopmost=$true;$script:desktopLeft=1088;$script:desktopTop=813

function Start-CompletionMonitor {}
function Test-WidgetCompletionForeground {return $script:testForeground}
function Test-WidgetCompletionHostForeground {return $script:testForeground}
function Start-TemporaryCompletion {return $false}
function Emit([string]$Id){Receive-CompletionMonitorLine ((@{type='completion';sessionId='test-chat';turnId=$Id;endedAt=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()}|ConvertTo-Json -Compress))}
function Close-TestBubble {if(!$script:collapsed){Hide-Quota};Drain-Wpf 550}
try{
  Initialize-WidgetAutoQuoteSettings $null;Initialize-CompletionNotificationState $null
  Assert (!$script:completionNotificationsEnabled -and !$script:completionPending) 'Reminders default off with no pending state'
  Initialize-CompletionNotificationState @{taskCompletionBubble='false'}
  Assert (!$script:completionNotificationsEnabled) 'String settings cannot accidentally enable a reminder'
  $script:testForeground=$true;$script:window.Opacity=0;$script:window.Show()
  Set-CompletionNotificationEnabled $true
  Assert $script:completionNotificationsEnabled 'Enabling reminder saves the chosen state'
  $saved=Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8|ConvertFrom-Json
  foreach($pair in @(@{key='scale';value=0.6},@{key='bubbleScale';value=1.0},@{key='soundVolume';value=0.37},@{key='characterId';value='gpt-dragon'},@{key='taskCompletionBubble';value=$true})){
    Assert ($saved.($pair.key)-eq $pair.value) ('Saving reminder changed '+$pair.key)
  }
  Receive-CompletionMonitorLine '{invalid'
  Receive-CompletionMonitorLine '{"type":"completion"}'
  Assert (!$script:completionPending) 'Malformed protocol data does not create a reminder'
  Emit 'one';Emit 'two';Emit 'three'
  Assert ($script:completionPending -and $script:completionReceived-eq 3) 'Multiple endings use one pending state'
  Tick-CompletionNotifications $false
  Assert ($script:collapsed -and $script:completionPending) 'Hidden widget retains the pending reminder'
  $script:testForeground=$false;Tick-CompletionNotifications $true
  Assert ($script:collapsed -and $script:completionPending) 'Unavailable background presentation preserves pending state'
  $script:testForeground=$true
  Show-Quota
  Tick-CompletionNotifications $true
  Assert ($script:bubbleMode-eq 'quota' -and $script:completionPending) 'Reminder waits behind manual quota'
  Close-TestBubble
  [IO.File]::Delete($refreshFile)
  Show-Quote;Tick-CompletionNotifications $true
  Assert ($script:bubbleMode-eq 'quote' -and $script:completionPending) 'Reminder waits behind manual quote'
  Close-TestBubble
  $quoteDecisions=$script:widgetQuoteLastByDataDir.Count
  foreach($guard in @('menu','drag','preview','gallery','editor')){
    switch($guard){
      'menu'{$script:context.IsOpen=$true}
      'drag'{$script:drag=@{moved=$true}}
      'preview'{$script:settingsSizePreview=$true}
      'gallery'{$script:characterGallery=@{IsVisible=$true}}
      'editor'{$script:quoteEditor=@{IsVisible=$true}}
    }
    Tick-CompletionNotifications $true
    Assert ($script:collapsed -and $script:completionDisplayCount-eq 0) ('Reminder ignores busy guard '+$guard)
    $script:context.IsOpen=$false;$script:drag=$null;$script:settingsSizePreview=$false;$script:characterGallery=$null;$script:quoteEditor=$null
  }
  Tick-CompletionNotifications $true
  Assert (!$script:collapsed -and $script:bubbleMode-eq 'completion' -and $script:completionDisplayCount-eq 1) 'Pending state directly opens one completion scene'
  Assert ($script:ui.QuoteText.Tag-ceq "Codex`n有回复已结束") 'Reminder explicitly separates the brand and the complete Chinese sentence'
  Assert ($script:quoteLayout.lines-eq 2) 'Reminder fits exactly two lines without wrapping its Chinese sentence'
  Assert (!(Test-Path -LiteralPath $refreshFile)) 'Reminder does not refresh quota'
  Assert ($script:widgetQuoteLastByDataDir.Count-eq $quoteDecisions) 'Reminder does not consume random quote selection'
  Assert (($script:sceneDeadline-$script:sceneStartedAt)-eq 5000) 'Reminder retains five seconds after the animation'
  $deadline=$script:sceneDeadline
  Emit 'four';Tick-CompletionNotifications $true
  Assert ($script:completionDisplayCount-eq 1 -and $script:sceneDeadline-eq $deadline) 'New endings merge without extending the active reminder'
  Drain-Wpf 650
  Assert ($script:ui.Bubble.Opacity-gt 0.99 -and $script:ui.SceneText.Opacity-gt 0.99 -and !$script:window.IsActive) 'Real WPF animation finishes without activation'
  # Inspect actual WPF glyph runs so this catches visual wrapping, not just a newline in the string.
  function Read-ReminderGlyphRows($drawing){
    if($drawing-is [Windows.Media.DrawingGroup]){
      foreach($child in $drawing.Children){Read-ReminderGlyphRows $child}
    }elseif($drawing-is [Windows.Media.GlyphRunDrawing]){
      $run=$drawing.GlyphRun
      foreach($character in $run.Characters){
        if([string]$character-match '[\u4e00-\u9fff]'){
          $script:reminderHanCount++;$script:reminderHanRows[[Math]::Round($run.BaselineOrigin.Y,2)]=$true
        }
      }
    }
  }
  foreach($facing in @(1,-1)){
    $script:ui.FacingScale.ScaleX=$facing;$script:ui.TextFacingScale.ScaleX=$facing
    foreach($bubbleSize in @(0.6,1.0,1.4,2.5)){
      $script:bubbleScale=$bubbleSize;Set-WidgetIndependentLayout
      $viewport=$script:window.Content;$size=378*(Get-WidgetLayoutScale)
      $viewport.Measure([Windows.Size]::new($size,$size));$viewport.Arrange([Windows.Rect]::new(0,0,$size,$size));$viewport.UpdateLayout()
      $script:reminderHanRows=@{};$script:reminderHanCount=0
      Read-ReminderGlyphRows ([Windows.Media.VisualTreeHelper]::GetDrawing($script:ui.QuoteText))
      Assert ($script:reminderHanCount-eq 6 -and $script:reminderHanRows.Count-eq 1) 'All six Chinese glyphs render on one actual WPF line at every supported size and facing'
    }
  }
  $script:bubbleScale=1.0;$script:ui.FacingScale.ScaleX=-1;$script:ui.TextFacingScale.ScaleX=-1;Set-WidgetIndependentLayout
  if($PreviewDirectory){
    $null=[IO.Directory]::CreateDirectory($PreviewDirectory)
    $viewport=$script:window.Content;$viewport.Measure([Windows.Size]::new(378,378));$viewport.Arrange([Windows.Rect]::new(0,0,378,378));$viewport.UpdateLayout()
    $render=[Windows.Media.Imaging.RenderTargetBitmap]::new(378,378,96,96,[Windows.Media.PixelFormats]::Pbgra32);$render.Render($viewport)
    $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($render))
    $stream=[IO.File]::Create((Join-Path $PreviewDirectory 'completion-quote.png'));try{$encoder.Save($stream)}finally{$stream.Dispose()}
  }
  $script:testForeground=$false;Tick-Scene ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
  Assert ($script:collapsed -and $script:completionPending) 'Losing foreground retracts rather than consumes reminder'
  Drain-Wpf 550;$script:testForeground=$true;Tick-CompletionNotifications $true
  Assert ($script:bubbleMode-eq 'completion' -and !$script:collapsed -and $script:completionDisplayCount-eq 2) 'Returning starts a fresh visible reminder'
  $script:settingsSizePreview=$true;Tick-Scene ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
  Assert ($script:collapsed -and $script:completionPending) 'Size preview interrupts reminder before general scene timer is paused'
  $script:settingsSizePreview=$false;Drain-Wpf 550;Tick-CompletionNotifications $true
  Assert (!$script:collapsed) 'Size preview release allows pending reminder to return'
  Show-Quota;Drain-Wpf 300
  Assert ($script:bubbleMode-eq 'quota' -and !$script:completionPending) 'Manual quota takes over and acknowledges the visible reminder'
  Close-TestBubble;Tick-CompletionNotifications $true
  Assert $script:collapsed 'Acknowledged reminder does not resurrect'
  Receive-CompletionMonitorLine ((@{type='completion';sessionId='test-chat';turnId='late';endedAt=$script:completionAcknowledgedAt-1000}|ConvertTo-Json -Compress))
  Assert (!$script:completionPending) 'Late events from before manual acknowledgement do not resurrect a reminder'
  Set-WidgetAutoQuoteSettings $true 60
  Emit 'next';$now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $script:autoQuoteLastTickAt=$now-1;$script:autoQuoteWasEligible=$true;$script:autoQuoteNextAt=$now-1
  Tick-WidgetAutoQuote $now $true
  Assert $script:collapsed 'Pending completion prevents a new due automatic quote'
  Tick-CompletionNotifications $true
  Tick-Scene ($script:sceneDeadline-1)
  Assert (!$script:collapsed) 'Reminder is visible before its natural deadline'
  Tick-Scene $script:sceneDeadline
  Assert ($script:collapsed -and !$script:completionPending) 'Natural ending acknowledges the whole merged reminder'
  Drain-Wpf 550;$now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();Tick-WidgetAutoQuote $now $true
  Assert ($script:collapsed -and $script:autoQuoteNextAt-ge $now+60000) 'Automatic quote starts a fresh full interval after reminder closes'
  Emit 'dismiss';Tick-CompletionNotifications $true;Next-Bubble
  Assert ($script:collapsed -and !$script:completionPending) 'Clicking the reminder consumes it'
  Drain-Wpf 550
  Emit 'disable-on-manual';Show-Quota;Set-CompletionNotificationEnabled $false
  Assert (!$script:collapsed -and $script:bubbleMode-eq 'quota' -and !$script:completionPending) 'Disabling clears pending state without closing manual content'
  Emit 'while-off'
  Assert (!$script:completionPending) 'Off state ignores late protocol data'
  Assert ((Get-CompletionNotificationStatus).monitorPid-eq 0) 'WPF state checks do not leave a child process'
  Write-Output ('PASS: '+$script:checks+' completion WPF checks: coalescing, manual priority, interaction guards, foreground pause, five-second animation, dismissal and auto-quote rescheduling')
}finally{
  foreach($timer in @($script:sceneTimer,$script:resetPhaseTimer,$script:closeTimer)){if($timer){$timer.Stop()}}
  $script:window.Close();Stop-CompletionMonitor
  $resolved=[IO.Path]::GetFullPath($script:dataDir);$allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
  if(!$resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved)-notlike 'gpt-niang-completion-wpf-*'){throw 'Unsafe completion WPF fixture cleanup path'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
