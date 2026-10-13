param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$appDir=Split-Path $TestRoot -Parent
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $appDir 'runtime\ui-settings.ps1'),[Text.Encoding]::UTF8)))
function Assert-Equal($actual,$expected,[string]$message){if($actual-ne $expected){throw "$message : expected '$expected', got '$actual'"}}
. (Join-Path $appDir 'runtime\completion-notifications.ps1')
$widgetSource=[IO.File]::ReadAllText((Join-Path $appDir 'widget.ps1'),[Text.Encoding]::UTF8)
$widgetTokens=$null;$widgetErrors=$null
$widgetAst=[Management.Automation.Language.Parser]::ParseInput($widgetSource,[ref]$widgetTokens,[ref]$widgetErrors)
if($widgetErrors.Count){throw ($widgetErrors|Out-String)}
foreach($name in @('Write-WidgetJson','Save-Settings')){
  $definition=$widgetAst.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq $name},$true)
  . ([ScriptBlock]::Create($definition.Extent.Text))
}
function Set-CompletionNotificationEnabled([bool]$Enabled){$script:completionNotificationsEnabled=$Enabled;Save-Settings}
function Set-WidgetFollowHost([bool]$Follow){$script:followHost=$Follow}
function Set-WidgetMenuBounds {}
function Position-WidgetMenuToHost {}
function Set-Appearance {}
function Set-WidgetAudioVolume {}
function Stop-WidgetAudio {}
. (Join-Path $appDir 'runtime\supervisor-task.ps1')
. (Join-Path $appDir 'runtime\update-common.ps1')
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $appDir 'runtime\update-ui.ps1'),[Text.Encoding]::UTF8)))
$script:dataDir=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-menu-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $script:dataDir
$script:settingsFile=Join-Path $script:dataDir 'settings.json'
$script:offsetRight=0;$script:offsetBottom=0;$script:offsetLeft=$null;$script:anchor='right';$script:side='right'
$script:config=@{version='1.3.2'}
Initialize-WidgetUpdater
$script:window=New-Object Windows.Window
$script:collapsed=$true;$script:bubbleMode='quota';$script:followHost=$true;$script:desktopTopmost=$true
$script:scale=1.0;$script:soundOn=$true;$script:soundVolume=0.9;$script:bubbleTapAdvance=$false;$script:hideMenu=$false
$script:completionNotificationsEnabled=$true
$script:colorMode='mixed';$script:colorChance=0.5;$script:colorTextChance=3;$script:colorPaused=$false
try{
  Initialize-WidgetSettingsMenu
  $expected=@('查看额度','换一句台词','刷新额度','编辑我的语录','显示与位置','外观设置','声音与点击','更新','退出 GPT 娘')
  $actual=@($script:context.Items|Where-Object{$_.Header-is [string]}|ForEach-Object{$_.Header})
  Assert-Equal ($actual-join '|') ($expected-join '|') 'Menu entries and removed title block'
  Assert-Equal $script:settingsMenuUi.UpdateVersion.Header '当前版本：1.3.2' 'Update menu shows actual version'
  Assert-Equal $script:settingsMenuUi.AutoUpdate.IsChecked $true 'Automatic updates are on initially'
  Assert-Equal (Get-CompletionNotificationPreference @{soundOn=$true}) $true 'Legacy settings default task reminders on'
  Assert-Equal (Get-CompletionNotificationPreference @{taskCompletionBubble=$false}) $false 'Saved opt-out remains disabled'
  Assert-Equal $script:settingsMenuUi.TaskCompletion.IsChecked $true 'Task completion bubbles are on by default'
  $script:settingsMenuUi.AutoUpdate.IsChecked=$false
  $script:settingsMenuUi.AutoUpdate.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  Assert-Equal (Read-WidgetUpdateJson (Join-Path $script:dataDir 'update-preferences.json')).automatic $false 'Menu toggle persists separately'
  Assert-Equal $script:settingsMenuUi.Topmost.Visibility Collapsed 'Window mode hides topmost'
  Assert-Equal $script:settingsMenuUi.TopmostDivider.Visibility Collapsed 'Window mode hides its divider'
  foreach($name in @('Follow','Desktop','Topmost','Hide','Sound','Tap','TaskCompletion')){
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
  $script:settingsMenuUi.Sound.IsChecked=$false
  $script:settingsMenuUi.Sound.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  Assert-Equal $script:settingsMenuUi.Volume.IsEnabled $false 'Muted sound disables volume control'
  $script:settingsMenuUi.TaskCompletion.IsChecked=$false
  $script:settingsMenuUi.TaskCompletion.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  Assert-Equal $script:completionNotificationsEnabled $false 'Task completion switch disables notifications'
  Assert-Equal (Get-Content -LiteralPath $script:settingsFile -Raw -Encoding UTF8|ConvertFrom-Json).taskCompletionBubble $false 'Task completion switch persists its setting'
  $script:settingsMenuUi.TaskCompletion.IsChecked=$true
  $script:settingsMenuUi.TaskCompletion.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  Assert-Equal (Get-Content -LiteralPath $script:settingsFile -Raw -Encoding UTF8|ConvertFrom-Json).taskCompletionBubble $true 'Task completion switch can be enabled again'
  Write-Output 'PASS: menu modes, conditional topmost, shared row styling, presets, sound controls and task-completion preference'
}finally{
  $script:window.Close()
  Assert-WidgetUpdateChildPath $script:dataDir ([IO.Path]::GetTempPath())
  Remove-Item -LiteralPath $script:dataDir -Recurse -Force
}
