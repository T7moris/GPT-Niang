param([string]$TestRoot=$PSScriptRoot,[string]$PreviewDirectory)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$appDir=Split-Path $TestRoot -Parent
. (Join-Path $appDir 'runtime\quotes.ps1')
foreach($module in @('quote-layout.ps1','color-theme.ps1','update-ui.ps1')){
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
$script:dataDir=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-auto-quote-'+[Guid]::NewGuid().ToString('N'))
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
try{
  Initialize-WidgetAutoQuoteSettings $null
  Assert (!$script:autoQuoteEnabled -and $script:autoQuoteIntervalSeconds-eq 300) 'Legacy settings must default to disabled, five minutes'
  Assert (!(Test-WidgetAutoQuoteDue 1000 $true $false) -and $script:autoQuoteNextAt-eq 0) 'Disabled quotes never schedule'
  foreach($seconds in @(60,300,900)){
    Initialize-WidgetAutoQuoteSettings @{autoQuoteEnabled=$true;autoQuoteIntervalSeconds=$seconds}
    $deadline=1000+[long]$seconds*1000
    Tick-ToBeforeDeadline 1000 $deadline
    Assert (Test-WidgetAutoQuoteDue $deadline $true $false) 'Supported interval must fire exactly at its deadline'
    Assert (!(Test-WidgetAutoQuoteDue $deadline $true $false)) 'Repeated tick must not fire twice'
  }
  foreach($bad in @(-1,0,30,59,60.1,86400,'invalid',$null)){
    Initialize-WidgetAutoQuoteSettings @{autoQuoteEnabled='true';autoQuoteIntervalSeconds=$bad}
    Assert (!$script:autoQuoteEnabled -and $script:autoQuoteIntervalSeconds-eq 300) 'Invalid saved fields must safely default'
  }
  $failed=$false;try{Set-WidgetAutoQuoteSettings $true 30}catch{$failed=$true}
  Assert $failed 'Unsupported interval must not be persisted'
  Set-WidgetAutoQuoteSettings $true 60
  $saved=Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8|ConvertFrom-Json
  foreach($pair in @(@{key='scale';value=0.6},@{key='bubbleScale';value=1.0},@{key='soundVolume';value=0.37},@{key='right';value=781.6},@{key='left';value=54.4},@{key='bottom';value=87.2},@{key='characterId';value='gpt-dragon'},@{key='soundOn';value=$false},@{key='hideMenu';value=$true})){
    Assert ($saved.($pair.key)-eq $pair.value) ('Saving auto quotes changed '+$pair.key)
  }
  Initialize-WidgetAutoQuoteSettings $saved
  Assert ($script:autoQuoteEnabled -and $script:autoQuoteIntervalSeconds-eq 60) 'Settings must survive actual Save-Settings and reload'
  Tick-ToBeforeDeadline 1000 61000
  Assert (!(Test-WidgetAutoQuoteDue 61000 $false $false)) 'Hidden widgets must not show a due quote'
  Assert (!(Test-WidgetAutoQuoteDue 62000 $true $false)) 'Becoming visible must restart the entire interval'
  Tick-ToBeforeDeadline 63000 122000
  Assert (Test-WidgetAutoQuoteDue 122000 $true $false) 'Visibility resume must wait one complete interval'
  Assert (!(Test-WidgetAutoQuoteDue 123000 $true $true)) 'Busy state pauses quotes'
  Assert (!(Test-WidgetAutoQuoteDue 124000 $true $false)) 'Leaving busy state must restart the interval'
  Tick-ToBeforeDeadline 125000 184000
  Assert (Test-WidgetAutoQuoteDue 184000 $true $false) 'Leaving busy state waits the complete interval'
  Assert (!(Test-WidgetAutoQuoteDue 1200000 $true $false)) 'A long gap must never show immediately on resume'
  Assert ($script:autoQuoteNextAt-eq 1260000) 'Resume must schedule from the current time'
  Assert (!(Test-WidgetAutoQuoteDue 1100000 $true $false)) 'A backwards clock change must restart safely'
  Assert ($script:autoQuoteNextAt-eq 1160000) 'Clock change must not leave an obsolete deadline'
  $null=Save-WidgetQuotes $script:dataDir @(@{text='这是自动语录测试，直接显示台词。';weight=1},@{text='操作结束后重新计时，不打断查看额度。';weight=1})
  Initialize-WidgetAutoQuoteSettings @{autoQuoteEnabled=$true;autoQuoteIntervalSeconds=60}
  Tick-ToBeforeDeadline 1000 60000
  foreach($guard in @('collapsed','drag','menu','preview','gallery','quote-editor','color-editor','closing')){
    switch($guard){
      'collapsed'{$script:collapsed=$false}
      'drag'{$script:drag=@{moved=$true}}
      'menu'{$script:context.IsOpen=$true}
      'preview'{$script:settingsSizePreview=$true}
      'gallery'{$script:characterGallery=@{IsVisible=$true}}
      'quote-editor'{$script:quoteEditor=@{IsVisible=$true}}
      'color-editor'{$script:colorTriggerEditor=@{IsVisible=$true}}
      'closing'{$script:closeTimer=@{IsEnabled=$true}}
    }
    $script:autoQuoteLastTickAt=60000;$script:autoQuoteWasEligible=$true;$script:autoQuoteNextAt=61000
    Tick-WidgetAutoQuote 61000 $true
    Assert ($script:autoQuoteDisplayCount-eq 0) ('Actual tick failed to defer '+$guard)
    $script:collapsed=$true;$script:drag=$null;$script:context.IsOpen=$false;$script:settingsSizePreview=$false
    $script:characterGallery=$null;$script:quoteEditor=$null;$script:colorTriggerEditor=$null;$script:closeTimer=$null
  }
  $script:window.Opacity=0;$script:window.Show()
  Assert (!$script:window.IsActive) 'Test overlay must not take focus'
  $script:autoQuoteLastTickAt=60000;$script:autoQuoteWasEligible=$true;$script:autoQuoteNextAt=61000
  Tick-WidgetAutoQuote 61000 $true
  Assert (!$script:collapsed -and $script:bubbleMode-eq 'quote' -and $script:autoQuoteDisplayCount-eq 1) 'Actual automatic tick must directly open one quote'
  Assert (!(Test-Path -LiteralPath $refreshFile)) 'Automatic quote must not trigger a quota refresh'
  Assert ($script:ui.QuotaText.Visibility-eq [Windows.Visibility]::Collapsed -and $script:ui.QuoteText.Visibility-eq [Windows.Visibility]::Visible) 'Automatic quote must use the quote scene immediately'
  Assert ($script:ui.Refresh.Visibility-eq [Windows.Visibility]::Collapsed) 'Quote scene must not expose quota refresh'
  Assert ($script:sceneTimer-eq $null -and $script:resetPhaseTimer-eq $null) 'Automatic quote must not enter quota or switch-scene timers'
  Assert (($script:sceneDeadline-$script:sceneStartedAt)-eq 5000) 'Quote must retain five full seconds after its opening animation'
  Assert (@('这是自动语录测试，直接显示台词。','操作结束后重新计时，不打断查看额度。')-contains $script:ui.QuoteText.Tag) 'Automatic quote must use the saved personal pool'
  $firstQuote=$script:ui.QuoteText.Tag
  Drain-Wpf 650
  Assert ($script:ui.Bubble.Opacity-gt 0.99 -and $script:ui.SceneText.Opacity-gt 0.99) 'Existing native WPF animation must finish cleanly'
  Assert (!$script:window.IsActive) 'Automatic quote must not activate the window'
  if($PreviewDirectory){
    $null=[IO.Directory]::CreateDirectory($PreviewDirectory)
    Set-WidgetIndependentLayout (Get-WidgetLayoutScale)
    $viewport=$script:window.Content;$viewport.Measure([Windows.Size]::new(350,350));$viewport.Arrange([Windows.Rect]::new(0,0,350,350));$viewport.UpdateLayout()
    $render=[Windows.Media.Imaging.RenderTargetBitmap]::new(350,350,96,96,[Windows.Media.PixelFormats]::Pbgra32);$render.Render($viewport)
    $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($render))
    $stream=[IO.File]::Create((Join-Path $PreviewDirectory 'auto-quote.png'));try{$encoder.Save($stream)}finally{$stream.Dispose()}
  }
  Tick-Scene ($script:sceneDeadline-1)
  Assert (!$script:collapsed) 'Quote must remain open through its entire readable interval'
  Tick-Scene $script:sceneDeadline
  Assert ($script:collapsed -and $script:closeTimer.IsEnabled) 'Deadline must start the existing closing animation'
  Drain-Wpf 550
  Assert ($script:ui.Bubble.Visibility-eq [Windows.Visibility]::Hidden -and !$script:closeTimer.IsEnabled) 'Closing timer must fully hide the quote'
  Show-Quote
  Assert ($script:ui.QuoteText.Tag-ne $firstQuote) 'Manual and automatic quote selection must share immediate-repeat avoidance'
  Assert (!(Test-Path -LiteralPath $refreshFile)) 'Direct manual quote also avoids a quota query'
  Show-Quota
  Drain-Wpf 300
  Assert ($script:bubbleMode-eq 'quota' -and $script:ui.QuotaText.Visibility-eq [Windows.Visibility]::Visible) 'Manual quota must take over an automatic quote'
  Hide-Quota;Drain-Wpf 550
  $script:displayRequestToken=$null
  Write-WidgetJson (Join-Path $script:dataDir 'display-request.json') @{mode='quota';nonce=[Guid]::NewGuid().ToString('N');at=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()}
  Read-DisplayRequest
  Tick-WidgetAutoQuote ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) $true
  Assert ($script:bubbleMode-eq 'quota' -and !$script:collapsed -and $script:autoQuoteDisplayCount-eq 1) 'Same-tick manual display must retain priority over automatic quotes'
  Assert (Test-Path -LiteralPath $refreshFile) 'Manual quota opening must retain its refresh request'
  Set-WidgetAutoQuoteSettings $false 900
  Initialize-WidgetAutoQuoteSettings (Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8|ConvertFrom-Json)
  Assert (!$script:autoQuoteEnabled -and $script:autoQuoteIntervalSeconds-eq 900) 'Disabling and restarting must retain the chosen interval'
  Write-Output ('PASS: '+$script:checks+' automatic quote checks, including native WPF open/close animation, saved personal quotes, refresh isolation, resume, manual takeover and retained settings')
}finally{
  foreach($timer in @($script:sceneTimer,$script:resetPhaseTimer,$script:closeTimer)){if($timer){$timer.Stop()}}
  $script:window.Close()
  $resolved=[IO.Path]::GetFullPath($script:dataDir)
  $allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
  if(!$resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved)-notlike 'gpt-niang-auto-quote-*'){throw 'Unsafe auto quote test cleanup path'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
