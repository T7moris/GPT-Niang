param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$appDir=Split-Path $TestRoot -Parent
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $appDir 'runtime\ui-settings.ps1'),[Text.Encoding]::UTF8)))
. (Join-Path $appDir 'runtime\quotes.ps1')
. (Join-Path $appDir 'runtime\audio.ps1')
Initialize-WidgetAutoQuoteSettings $null
. (Join-Path $appDir 'runtime\completion-notifications.ps1')
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $appDir 'runtime/music.ps1'),[Text.Encoding]::UTF8)))
Initialize-CompletionNotificationState $null
function Assert-Equal($actual,$expected,[string]$message){if($actual-ne $expected){throw "$message : expected '$expected', got '$actual'"}}
function Save-Settings {}
function Set-WidgetFollowHost([bool]$Follow){$script:followHost=$Follow}
function Set-WidgetMenuBounds {}
function Position-WidgetMenuToHost {}
function Set-Appearance {}
function Restart-SceneTtl {}
$widgetSource=[IO.File]::ReadAllText((Join-Path $appDir 'widget.ps1'),[Text.Encoding]::UTF8)
$tokens=$null;$errors=$null
$widgetAst=[Management.Automation.Language.Parser]::ParseInput($widgetSource,[ref]$tokens,[ref]$errors)
foreach($name in @('Set-AnimatedValue','Set-BubbleState')){
  $definition=$widgetAst.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq $name},$true)
  . ([ScriptBlock]::Create($definition.Extent.Text))
}
$poseWindow=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $appDir 'widget.xaml'),[Text.Encoding]::UTF8))
$script:ui=@{}
foreach($name in @('Bubble','Tail','TailNear','SceneText')){$script:ui[$name]=$poseWindow.FindName($name)}
function Set-WidgetAudioVolume {}
function Stop-WidgetAudio {}
function Set-CompletionNotificationEnabled([bool]$Enabled){$script:completionNotificationsEnabled=$Enabled}
function Set-CompletionVoiceEnabled([bool]$Enabled){$script:completionVoiceEnabled=$Enabled}
function Set-QuoteVoiceEnabled([bool]$Enabled){$script:quoteVoiceEnabled=$Enabled}
. (Join-Path $appDir 'runtime\supervisor-task.ps1')
. (Join-Path $appDir 'runtime\update-common.ps1')
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $appDir 'runtime\update-ui.ps1'),[Text.Encoding]::UTF8)))
$script:dataDir=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-menu-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $script:dataDir
$script:config=@{version='1.3.2'}
Initialize-WidgetUpdater
$script:window=New-Object Windows.Window
$script:collapsed=$true;$script:bubbleMode='quota';$script:followHost=$true;$script:desktopTopmost=$true
$script:scale=1.0;$script:bubbleScale=1.0;$script:soundOn=$true;$script:soundVolume=0.9;$script:bubbleTapAdvance=$false;$script:hideMenu=$false
$script:colorMode='mixed';$script:colorChance=0.5;$script:colorTextChance=3;$script:colorPaused=$false
try{
  $script:galleryOpenCount=0
  function Open-WidgetCharacterGallery {$script:galleryOpenCount++}
  Initialize-WidgetSettingsMenu
  Assert-Equal $script:settingsMenuUi.AudioBuiltin.IsCheckable $true 'Builtin audio is a radio choice'
  Assert-Equal $script:settingsMenuUi.AudioCustom.IsCheckable $true 'Custom audio is a radio choice'
  $audioHandler=${function:Invoke-WidgetAudioAction};$script:audioCommands=@()
  function Invoke-WidgetAudioAction([string]$Action,[string]$Slot){$script:audioCommands+=@{action=$Action;slot=$Slot}}
  try{
    foreach($slot in @('press','release')){
      $items=@($script:settingsMenuUi['AudioSlot_'+$slot].Items)
      foreach($action in @(@{title='选择WAV';name='import'},@{title='设为无声';name='clear'},@{title='试听';name='preview'})){
        $item=@($items|Where-Object{$_.Header-is [string] -and $_.Header.StartsWith($action.title)})[0]
        $item.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
        $record=$script:audioCommands[-1]
        Assert-Equal $record.slot $slot 'Audio menu retains the correct independent phase'
        Assert-Equal $record.action $action.name 'Audio menu dispatches the intended operation'
      }
    }
  }finally{${function:Invoke-WidgetAudioAction}=$audioHandler}
  $script:audioDialogOpen=$true
  Assert-Equal (Test-WidgetUpdateEditor) $true 'Audio dialogs defer reminder and update activity'
  $script:audioDialogOpen=$false
  $script:settingsMenuUi.Character.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  Assert-Equal $script:galleryOpenCount 1 'Main menu opens character selection'
  $script:characterGallery=[pscustomobject]@{IsVisible=$true}
  Assert-Equal (Test-WidgetUpdateEditor) $true 'Open character gallery defers updater installation'
  $script:characterGallery=$null
  Assert-Equal (Test-WidgetUpdateEditor) $false 'Closed gallery returns to updater idle'
  $expected=@('查看额度','刷新额度','换一句台词','更换形象','外观设置','声音与点击','编辑我的语录','音乐律动','自动语录','回答结束提醒','显示与位置','更新','退出 GPT 娘')
  Assert-Equal $script:settingsMenuUi.MusicEnabled.IsChecked $false 'Music capture starts only after an explicit enable'
  Assert-Equal $script:settingsMenuUi.MusicEnabled.Items.Count 0 'Music is one direct toggle without a second mode'
  Assert-Equal ($null-eq $script:settingsMenuUi.MusicColor) $true 'Music color has no separate toggle'
  $actual=@($script:context.Items|Where-Object{$_.Header-is [string]}|ForEach-Object{$_.Header})
  Assert-Equal ($actual-join '|') ($expected-join '|') 'Menu entries and removed title block'
  Assert-Equal $script:settingsMenuUi.Completion.IsChecked $false 'Reply reminders default off'
  Assert-Equal $script:settingsMenuUi.Completion.StaysOpenOnClick $true 'Reply reminder toggle retains menu interaction'
  Assert-Equal $script:settingsMenuUi.AutoQuoteEnabled.IsChecked $false 'Automatic quotes default off'
  Assert-Equal (@($script:settingsMenuUi.AutoQuoteIntervals|Where-Object{$_.IsChecked}).Count) 1 'One interval is selected'
  Assert-Equal (@($script:settingsMenuUi.AutoQuoteIntervals|Where-Object{$_.IsChecked})[0].Tag) 300 'Default interval is five minutes'
  foreach($choice in $script:settingsMenuUi.AutoQuoteIntervals){
    $choice.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
    Assert-Equal $script:autoQuoteIntervalSeconds ([int]$choice.Tag) 'Interval row applies its own value'
    Assert-Equal $script:autoQuoteEnabled $false 'Choosing an interval does not enable quotes'
    Assert-Equal (@($script:settingsMenuUi.AutoQuoteIntervals|Where-Object{$_.IsChecked}).Count) 1 'Interval rows remain mutually exclusive'
  }
  $script:settingsMenuUi.AutoQuoteEnabled.IsChecked=$true
  $script:settingsMenuUi.AutoQuoteEnabled.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  Assert-Equal $script:autoQuoteEnabled $true 'Menu enables automatic quotes'
  $script:settingsMenuUi.AutoQuoteEnabled.IsChecked=$false
  $script:settingsMenuUi.AutoQuoteEnabled.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  Assert-Equal $script:autoQuoteEnabled $false 'Menu disables automatic quotes'
  Assert-Equal $script:autoQuoteIntervalSeconds 900 'Disabling remembers the selected interval'
  Assert-Equal $script:settingsMenuUi.AutoQuoteEnabled.StaysOpenOnClick $true 'Toggle retains the menu'
  Assert-Equal $script:settingsMenuUi.UpdateVersion.Header '当前版本：1.3.2' 'Update menu shows actual version'
  Assert-Equal $script:settingsMenuUi.AutoUpdate.IsChecked $true 'Automatic updates are on initially'
  $script:settingsMenuUi.AutoUpdate.IsChecked=$false
  $script:settingsMenuUi.AutoUpdate.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  Assert-Equal (Read-WidgetUpdateJson (Join-Path $script:dataDir 'update-preferences.json')).automatic $false 'Menu toggle persists separately'
  Assert-Equal $script:settingsMenuUi.Topmost.Visibility Collapsed 'Window mode hides topmost'
  Assert-Equal $script:settingsMenuUi.TopmostDivider.Visibility Collapsed 'Window mode hides its divider'
  foreach($name in @('Follow','Desktop','Topmost','Hide','Sound','Tap')){
    Assert-Equal $script:settingsMenuUi[$name].StaysOpenOnClick $true 'All settings retain menu interaction'
    Assert-Equal $script:settingsMenuUi[$name].Style $script:settingsMenuResources['SettingsItem'] 'Rows share the same style'
  }
  $script:settingsMenuUi.Desktop.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  Assert-Equal $script:followHost $false 'Desktop row selects desktop mode'
  Assert-Equal $script:settingsMenuUi.Follow.IsChecked $false 'Modes are mutually exclusive'
  Assert-Equal $script:settingsMenuUi.Desktop.IsChecked $true 'Selected desktop indicator'
  Assert-Equal $script:settingsMenuUi.Topmost.Visibility Visible 'Desktop mode exposes topmost'
  Assert-Equal $script:settingsMenuUi.Topmost.IsChecked $true 'Remembered desktop preference'
  $script:settingsMenuUi.Follow.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  Assert-Equal $script:followHost $true 'Window row selects window mode'
  Assert-Equal $script:settingsMenuUi.Desktop.IsChecked $false 'Desktop indicator clears'
  Assert-Equal $script:settingsMenuUi.Topmost.Visibility Collapsed 'Topmost disappears immediately'
  Assert-Equal $script:desktopTopmost $true 'Switching modes retains desktop preference'
  $script:settingsMenuUi.SizeButtons[2].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Assert-Equal $script:scale 1.4 'Preset updates actual size'
  Assert-Equal $script:sizeSlider.Value 1.4 'Preset and slider stay synchronized'
  $script:bubbleSizeSlider.Value=1.2
  Assert-Equal $script:bubbleScale 1.2 'Bubble slider changes bubble size'
  Assert-Equal $script:scale 1.4 'Bubble slider preserves character size'
  $script:sizeSlider.Value=0.6
  Assert-Equal $script:scale 0.6 'Character slider changes character size'
  Assert-Equal $script:bubbleScale 1.2 'Character slider preserves bubble size'
  Update-WidgetSettingsMenu
  Assert-Equal $script:settingsMenuUi.SizeText.Text '60%' 'Character label follows character size'
  Assert-Equal $script:settingsMenuUi.BubbleSizeText.Text '120%' 'Bubble label follows bubble size'
  $script:settingsMenuUi.Appearance.ApplyTemplate()|Out-Null
  $appearancePopup=$script:settingsMenuUi.Appearance.Template.FindName('PART_Popup',$script:settingsMenuUi.Appearance)
  if(!$appearancePopup.Child){throw 'The actual appearance popup template must exist for preview testing'}
  foreach($slider in @($script:sizeSlider,$script:bubbleSizeSlider)){
    $started=[Windows.Controls.Primitives.DragStartedEventArgs]::new(0,0)
    $started.RoutedEvent=[Windows.Controls.Primitives.Thumb]::DragStartedEvent
    $script:collapsed=$true;Set-BubbleState
    $slider.RaiseEvent($started)
    $expectedBubble=if($slider-eq $script:bubbleSizeSlider){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Hidden}
    foreach($name in @('Bubble','Tail','TailNear')){Assert-Equal $script:ui[$name].Visibility $expectedBubble 'Bubble-size drag temporarily shows the actual bubble and tails'}
    Assert-Equal $script:collapsed $true 'Preview must not change the persisted collapsed preference'
    Assert-Equal $script:context.Opacity 0.08 'Dragging fades the main settings menu'
    Assert-Equal $appearancePopup.Child.Opacity 0.08 'Dragging also fades the separate submenu popup'
    Assert-Equal $script:context.IsHitTestVisible $true 'Transparent settings retain mouse interaction'
    $completed=[Windows.Controls.Primitives.DragCompletedEventArgs]::new(0,0,$false)
    $completed.RoutedEvent=[Windows.Controls.Primitives.Thumb]::DragCompletedEvent
    $slider.RaiseEvent($completed)
    Assert-Equal $script:ui.Bubble.Visibility Hidden 'Release restores the originally closed bubble'
    Assert-Equal $script:context.Opacity 1 'Releasing restores the main menu'
    Assert-Equal $appearancePopup.Child.Opacity 1 'Releasing restores the submenu'
    $slider.RaiseEvent($started)
    $lost=[Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0)
    $lost.RoutedEvent=[Windows.UIElement]::LostMouseCaptureEvent
    $slider.RaiseEvent($lost)
    Assert-Equal $script:ui.Bubble.Visibility Hidden 'Lost capture restores the originally closed bubble'
    Assert-Equal $script:context.Opacity 1 'Lost capture also restores settings'
  }
  $pressed=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0,[Windows.Input.MouseButton]::Left)
  $pressed.RoutedEvent=[Windows.UIElement]::PreviewMouseLeftButtonDownEvent
  $script:sizeSlider.RaiseEvent($pressed)
  Assert-Equal $script:context.Opacity 0.08 'Clicking the track previews size too'
  $released=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0,[Windows.Input.MouseButton]::Left)
  $released.RoutedEvent=[Windows.UIElement]::PreviewMouseLeftButtonUpEvent
  $script:sizeSlider.RaiseEvent($released)
  Assert-Equal $script:context.Opacity 1 'Track release restores settings'
  $script:sizeSlider.RaiseEvent($pressed)
  $script:context.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.ContextMenu]::ClosedEvent))
  Assert-Equal $script:context.Opacity 1 'Closing the menu cannot leave it transparent'
  Assert-Equal $appearancePopup.Child.Opacity 1 'Closing restores the independent popup too'
  $script:collapsed=$false;Set-BubbleState
  $script:bubbleSizeSlider.RaiseEvent($started)
  $script:bubbleSizeSlider.RaiseEvent($completed)
  Assert-Equal $script:ui.Bubble.Visibility Visible 'An originally open bubble remains open after preview'
  Assert-Equal $script:collapsed $false 'Open preference stays open'
  $script:collapsed=$true;Set-BubbleState
  $script:bubbleSizeSlider.RaiseEvent($pressed)
  Assert-Equal $script:ui.Bubble.Visibility Visible 'Clicking the bubble track previews a closed bubble'
  $script:context.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.ContextMenu]::ClosedEvent))
  Assert-Equal $script:ui.Bubble.Visibility Hidden 'Closing the menu restores a temporary bubble'
  $script:bubbleSizeSlider.RaiseEvent($started)
  $handle=([Windows.Interop.WindowInteropHelper]::new($script:window)).EnsureHandle()
  $inputSource=[Windows.Interop.HwndSource]::FromHwnd($handle)
  $escape=[Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,$inputSource,0,[Windows.Input.Key]::Escape)
  $escape.RoutedEvent=[Windows.UIElement]::PreviewKeyDownEvent
  $script:bubbleSizeSlider.RaiseEvent($escape)
  Assert-Equal $script:context.Opacity 1 'Escape restores size-preview opacity'
  Assert-Equal $script:ui.Bubble.Visibility Hidden 'Escape restores the originally collapsed bubble'
  $script:bubbleSizeSlider.RaiseEvent($started)
  $script:bubbleSizeSlider.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.FrameworkElement]::UnloadedEvent))
  Assert-Equal $script:context.Opacity 1 'Unloading the slider restores size-preview opacity'
  Assert-Equal $script:settingsSizePreview $false 'Unloading does not leave an active preview'
  $script:settingsMenuUi.Sound.IsChecked=$false
  $script:settingsMenuUi.Sound.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  Assert-Equal $script:settingsMenuUi.Volume.IsEnabled $false 'Muted sound disables volume control'
  $script:settingsMenuUi.QuoteVoice.IsChecked=$false
  $script:settingsMenuUi.QuoteVoice.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  Assert-Equal $script:quoteVoiceEnabled $false 'Quote voice can be muted independently'
  $script:settingsMenuUi.CompletionVoice.IsChecked=$true
  $script:settingsMenuUi.CompletionVoice.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  Assert-Equal $script:completionVoiceEnabled $true 'Completion voice remains independent'
  Write-Output 'PASS: menu modes, conditional topmost, shared row styling, presets and sound controls'
}finally{
  $poseWindow.Close()
  $script:window.Close()
  Assert-WidgetUpdateChildPath $script:dataDir ([IO.Path]::GetTempPath())
  Remove-Item -LiteralPath $script:dataDir -Recurse -Force
}
