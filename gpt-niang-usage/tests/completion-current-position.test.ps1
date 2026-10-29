param([string]$TestRoot=$PSScriptRoot,[string]$PreviewDirectory)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$appDir=Split-Path $TestRoot -Parent
. (Join-Path $appDir 'runtime\sharp-text.ps1')
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
foreach($name in @('Set-AnimatedValue','Animate-Value','Set-BubbleState','Get-WidgetLayoutScale','Set-WidgetIndependentLayout','Reset-Label','Format-ResetTime','Format-ResetDisplay','Set-QuotaResetText','Get-QuotaWindowLabel','Get-QuotaRows','Set-ResetTimeMode','Restart-SceneTtl','Tick-Scene','Apply-Scene','Update-BubbleTooltip','Switch-Scene','Show-Quote','Show-Quota','Open-WidgetBubble','Hide-Quota','Tick-WidgetAutoQuote','Write-WidgetJson','Save-Settings','Read-DisplayRequest','Request-Refresh','Next-Bubble','Click-Character')){
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
$script:window=[Windows.Markup.XamlReader]::Parse((ConvertTo-SmoothWidgetXaml ([IO.File]::ReadAllText((Join-Path $appDir 'widget.xaml'),[Text.Encoding]::UTF8)) -AppDir $appDir))
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
function Emit([string]$Id){Receive-CompletionMonitorLine ((@{type='completion';sessionId='test-chat';turnId=$Id;endedAt=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()}|ConvertTo-Json -Compress))}
function Close-TestBubble {if(!$script:collapsed){Hide-Quota};Drain-Wpf 550}

Add-Type -AssemblyName System.Windows.Forms,System.Drawing
function Test-CompletionFullscreen([IntPtr]$Handle){return $script:testFullscreen}
$script:testFullscreen=$false
function Rect-Key {
  $r=New-Object CompletionWindowLayer+Rect;$null=[CompletionWindowLayer]::GetWindowRect($script:widgetHandle,[ref]$r)
  return "$($r.Left),$($r.Top),$($r.Right),$($r.Bottom)"
}
try{
  Initialize-WidgetAutoQuoteSettings $null;Initialize-CompletionNotificationState $null
  $script:window.Opacity=0;$script:window.Show();$script:widgetHandle=([Windows.Interop.WindowInteropHelper]::new($script:window)).Handle
  $beforeRect=Rect-Key;$beforeStyle=[CompletionWindowLayer]::GetWindowLongPtr($script:widgetHandle,-20);$beforeOwner=[CompletionWindowLayer]::GetWindowLongPtr($script:widgetHandle,-8)
  $script:testForeground=$false;Set-CompletionNotificationEnabled $true
  Emit 'background';Tick-CompletionNotifications $false
  Assert ([bool]$script:completionTemporary -and !$script:collapsed -and $script:bubbleMode-eq 'completion') 'Background uses the original widget instead of another window'
  Assert ((Rect-Key)-eq $beforeRect) 'Temporary topmost never changes native position or physical size'
  Assert ($script:window.Topmost -and ([CompletionWindowLayer]::GetWindowLongPtr($script:widgetHandle,-20).ToInt64()-band 8)-ne 0) 'Original widget really enters the topmost band'
  Assert ([CompletionWindowLayer]::GetWindowLongPtr($script:widgetHandle,-8)-eq [IntPtr]::Zero) 'Temporary reminder is detached from minimized/covered Codex ownership'
  Assert ($script:ui.QuoteText.Text-ceq "Codex`n有回复已结束") 'Original reminder retains one complete Chinese line'
  Save-Settings;$prefs=Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8|ConvertFrom-Json
  foreach($pair in @(@{k='scale';v=0.6},@{k='bubbleScale';v=1.0},@{k='left';v=54.4},@{k='bottom';v=87.2},@{k='followHost';v=$true},@{k='side';v='left'})){
    Assert ($prefs.($pair.k)-eq $pair.v) ('Temporary layer leaked into saved '+$pair.k)
  }
  $deadline=$script:sceneDeadline;Emit 'merged';Tick-CompletionNotifications $false
  Assert ($script:completionDisplayCount-eq 1 -and $script:sceneDeadline-eq $deadline) 'Multiple endings merge without restarting or flashing'
  $script:sceneDeadline=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()-1;Drain-Wpf 150
  Assert (!$script:completionTemporary -and $script:collapsed -and !$script:completionPending) 'Natural end restores the original display'
  Assert ((Rect-Key)-eq $beforeRect -and [CompletionWindowLayer]::GetWindowLongPtr($script:widgetHandle,-20)-eq $beforeStyle) 'Native position, size and extended style fully restore'
  Assert ([CompletionWindowLayer]::GetWindowLongPtr($script:widgetHandle,-8)-eq $beforeOwner -and !$script:window.Topmost) 'Original owner and WPF topmost restore'
  Drain-Wpf 550
  Emit 'return';Tick-CompletionNotifications $false;$script:testForeground=$true;Drain-Wpf 150
  Assert (!$script:completionTemporary -and !$script:completionPending -and $script:collapsed) 'Returning to Codex restores display without a second reminder'
  Drain-Wpf 550;$script:testForeground=$false;$script:testFullscreen=$true
  Emit 'fullscreen';Tick-CompletionNotifications $false
  Assert ([bool]$script:completionTemporary) 'Fullscreen ending can start the temporary original-widget presentation'
  $script:testFullscreen=$false;Drain-Wpf 150
  Assert (!$script:completionTemporary -and !$script:completionPending) 'Leaving the originating fullscreen restores the saved layer'
  Drain-Wpf 550;Emit 'manual';Show-Quota;Tick-CompletionNotifications $false
  Assert (!$script:completionTemporary -and $script:bubbleMode-eq 'quota' -and $script:completionPending) 'Manual content retains priority'
  Close-TestBubble;Tick-CompletionNotifications $false
  $script:context.IsOpen=$true;Tick-CompletionNotifications $true
  Assert (!$script:completionTemporary -and $script:completionPending) 'Menu interruption restores layer and keeps the pending event'
  $script:context.IsOpen=$false;Drain-Wpf 550;Tick-CompletionNotifications $false
  Set-CompletionNotificationEnabled $false
  Assert (!$script:completionTemporary -and !$script:completionPending -and !$script:window.Topmost) 'Disabling restores rather than leaving topmost behind'
  Drain-Wpf 550;$script:window.Hide();Set-CompletionNotificationEnabled $true;Emit 'originally-hidden';Tick-CompletionNotifications $false
  Assert ($script:window.IsVisible -and $script:completionTemporary -and !$script:completionTemporary.visible) 'A previously hidden original window is shown temporarily'
  Set-CompletionNotificationEnabled $false
  Assert (!$script:window.IsVisible) 'A previously hidden widget returns to hidden after the reminder'
  Write-WidgetJson (Join-Path $script:dataDir 'display-request.json') @{mode='completion';at=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();nonce=[Guid]::NewGuid().ToString('N')}
  Read-DisplayRequest
  Assert (!$script:completionPending) 'Local verification request respects the disabled reminder toggle'
  Set-CompletionNotificationEnabled $true;Drain-Wpf 550
  Write-WidgetJson (Join-Path $script:dataDir 'display-request.json') @{mode='completion';at=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();nonce=[Guid]::NewGuid().ToString('N')}
  Read-DisplayRequest;Tick-CompletionNotifications $false
  Assert ([bool]$script:completionTemporary) 'Local verification can exercise the original UI without editing real logs or restarting the widget'
  Set-CompletionNotificationEnabled $false
  Write-Output ('PASS: '+$script:checks+' current-position reminder checks: same HWND, no move/resize, topmost/owner/style restoration, fullscreen exit, return, coalescing, saved preferences and hidden state')
}finally{
  Stop-CompletionMonitor
  foreach($timer in @($script:sceneTimer,$script:resetPhaseTimer,$script:closeTimer)){if($timer){$timer.Stop()}}
  $script:window.Close()
  $resolved=[IO.Path]::GetFullPath($script:dataDir);$allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
  if(!$resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved)-notlike 'gpt-niang-completion-wpf-*'){throw 'Unsafe current-position fixture cleanup path'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
