param([string]$TestRoot=$PSScriptRoot,[string]$PreviewDirectory)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$script:appDir=Split-Path $TestRoot -Parent
foreach($module in @('character-theme.ps1','color-theme.ps1','ui-settings.ps1','quotes.ps1','audio.ps1','music.ps1','completion-notifications.ps1','supervisor-task.ps1','update-common.ps1','update-ui.ps1')){
  if($module-eq 'quotes.ps1'){. (Join-Path $script:appDir ('runtime\'+$module))}
  else{. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir ('runtime\'+$module)),[Text.Encoding]::UTF8)))}
}
function Assert($Condition,[string]$Message){if(!$Condition){throw $Message}}
function Save-Settings {}
$ast=[Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText((Join-Path $script:appDir 'widget.ps1'),[Text.Encoding]::UTF8),[ref]$null,[ref]$null)
foreach($name in @('Get-QuotaWindowLabel','Get-QuotaRows')){
  $definition=$ast.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq $name},$true)
  . ([ScriptBlock]::Create($definition.Extent.Text))
}
$script:dataDir=Join-Path $TestRoot ('theme-ui-fixture-'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($script:dataDir)
try{
  Initialize-WidgetCharacterTheme $script:dataDir
  $script:window=Read-WidgetThemedXaml ([IO.File]::ReadAllText((Join-Path $script:appDir 'widget.xaml'),[Text.Encoding]::UTF8))
  $script:ui=@{}
  foreach($name in @('Root','Bubble','Tail','TailNear','BubbleShape','Girl','Header','QuoteText','Refresh','MenuButton','ShortLeft','ShortBar','WeekLeft','WeekBar')){$script:ui[$name]=$script:window.FindName($name)}
  $pixels=New-Object byte[] (64*64*4)
  for($i=0;$i-lt $pixels.Length;$i+=4){$pixels[$i]=185;$pixels[$i+1]=215;$pixels[$i+2]=180;$pixels[$i+3]=255}
  $script:bitmap=[Windows.Media.Imaging.BitmapSource]::Create(64,64,96,96,[Windows.Media.PixelFormats]::Bgra32,$null,$pixels,256);$script:bitmap.Freeze();$script:ui.Girl.Source=$script:bitmap
  $script:activeCharacter=[pscustomobject]@{id='test-green';kind='built-in';name='绿色测试';path=(Join-Path $script:dataDir 'green.png')};[IO.File]::WriteAllText($script:activeCharacter.path,'signature')
  $script:characterId=$script:activeCharacter.id;$script:collapsed=$true;$script:bubbleMode='quota';$script:colorMode='original'
  $script:status=@{windows=@(@{minutes=300;used=20;resetsAt=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600)},@{minutes=10080;used=95;resetsAt=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600)})}
  Initialize-WidgetColors
  Set-WidgetCharacterThemeMode 'character'
  $stroke=$script:ui.BubbleShape.Stroke.Color
  Assert ($stroke.G-gt $stroke.R -and $stroke.G-gt $stroke.B) 'Actual bubble must adopt the current character palette'
  Assert ($script:ui.WeekLeft.Foreground.Color.ToString()-eq '#FFB74839') 'Low quota remains red'
  Assert ($script:ui.WeekBar.Background.Color.ToString()-eq '#FFD77659') 'Low quota progress remains red'
  Assert ([Object]::ReferenceEquals($script:bitmap,$script:ui.Girl.Source)) 'A static theme never recolors the character bitmap'
  $readStamp=[IO.File]::GetLastWriteTimeUtc($script:characterThemeFile)
  Update-WidgetCharacterTheme
  Assert ([IO.File]::GetLastWriteTimeUtc($script:characterThemeFile)-eq $readStamp) 'Cached palette application does not decode or rewrite the theme cache'
  $script:config=@{version='1.3.5'};Initialize-WidgetUpdater;Initialize-WidgetAutoQuoteSettings $null;Initialize-CompletionNotificationState $null
  $script:followHost=$true;$script:desktopTopmost=$false;$script:scale=0.8;$script:bubbleScale=1.0;$script:soundOn=$true;$script:soundVolume=0.8;$script:hideMenu=$false
  Initialize-WidgetSettingsMenu
  Assert ([bool]$script:settingsMenuUi.CharacterTheme) 'Appearance contains the character-theme submenu'
  Assert $script:settingsMenuUi.ThemeFollow.IsChecked 'The follow-character toggle reflects saved mode'
  $script:context.ApplyTemplate()|Out-Null
  $menuBorder=[Windows.Media.VisualTreeHelper]::GetChild($script:context,0)
  Assert ($menuBorder.Background.Color.G-gt $menuBorder.Background.Color.R) 'Actual settings-menu surface follows character hue'
  $script:sizeSlider.ApplyTemplate()|Out-Null
  $track=$script:sizeSlider.Template.FindName('PART_Track',$script:sizeSlider);$track.Thumb.ApplyTemplate()|Out-Null
  $thumbBorder=[Windows.Media.VisualTreeHelper]::GetChild($track.Thumb,0)
  Assert ($thumbBorder.BorderBrush.Color.G-gt $thumbBorder.BorderBrush.Color.R) 'Slider thumb uses the live character accent inside the real template'
  $script:settingsMenuUi.ThemeFollow.IsChecked=$false
  $script:settingsMenuUi.ThemeFollow.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  Assert ($script:characterThemeState.mode-eq 'default') 'Menu toggle turns theme off'
  Assert ($script:ui.BubbleShape.Stroke.Color.ToString()-eq '#FF745A98') 'Default toggle restores exact original purple'
  $script:settingsMenuUi.ThemeFollow.IsChecked=$true
  $script:settingsMenuUi.ThemeFollow.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  Set-WidgetCharacterThemeColor '#E38D4C'
  Assert ($script:ui.BubbleShape.Stroke.Color.R-gt $script:ui.BubbleShape.Stroke.Color.G) 'Manual override immediately changes the live bubble'
  Assert ($menuBorder.Background.Color.R-gt $menuBorder.Background.Color.G) 'Existing menu resources update without rebuilding or opening extra windows'
  $script:colorMode='rainbow';Update-WidgetColorScene
  $script:colorMode='original';Update-WidgetColorScene
  Assert ($script:ui.BubbleShape.Stroke.Color.R-gt $script:ui.BubbleShape.Stroke.Color.G) 'Returning from animated color restores the selected static theme'
  $snapshot=[IO.File]::ReadAllText($script:characterThemeFile)
  $failed=$false;try{Set-WidgetCharacterThemeColor 'invalid'}catch{$failed=$true}
  Assert $failed 'Invalid manual colors are rejected'
  Assert ([IO.File]::ReadAllText($script:characterThemeFile)-eq $snapshot) 'Invalid colors cannot corrupt persisted preferences'
  $script:window.Left=-10000;$script:window.Top=-10000;$script:window.ShowActivated=$false;$script:window.Show()
  Open-WidgetCharacterThemeEditor
  Assert $script:characterThemeEditor.IsVisible 'The real color editor opens'
  Assert (Test-WidgetUpdateEditor) 'Updates defer while the color editor is open'
  $script:characterThemeEditor.FindName('Hex').Text='#477CAF'
  $script:characterThemeEditor.FindName('Apply').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Assert ($script:characterThemeState.characters[$script:activeCharacter.id].manualColor-eq '#477CAF') 'Editor Apply saves the actual typed color'
  $swatch=$script:characterThemeEditor.FindName('Candidates').Children[0]
  $swatch.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Assert ($script:characterThemeState.characters[$script:activeCharacter.id].manualColor-eq $swatch.Tag) 'Candidate swatch applies its own image color'
  $script:activeCharacter=[pscustomobject]@{id='test-other';kind='built-in';name='Other';path=$script:activeCharacter.path}
  Update-WidgetCharacterTheme
  Assert (!$script:characterThemeEditor) 'Changing character closes an editor with stale image candidates'
  $script:window.Hide()
  if($PreviewDirectory){
    $null=[IO.Directory]::CreateDirectory($PreviewDirectory)
    foreach($choice in @(@{name='green';color='#B4D7B9'},@{name='orange';color='#E38D4C'})){
      Set-WidgetCharacterThemeColor $choice.color
      $script:ui.Bubble.Visibility=[Windows.Visibility]::Visible;$script:ui.Tail.Visibility=[Windows.Visibility]::Visible;$script:ui.TailNear.Visibility=[Windows.Visibility]::Visible
      $script:ui.Girl.Source=[Windows.Media.Imaging.BitmapImage]::new([Uri](Join-Path $script:appDir 'assets\gpt-dragon-niang-bust.png'))
      $viewport=$script:window.Content;$viewport.Measure([Windows.Size]::new(378,378));$viewport.Arrange([Windows.Rect]::new(0,0,378,378));$viewport.UpdateLayout()
      $render=[Windows.Media.Imaging.RenderTargetBitmap]::new(378,378,96,96,[Windows.Media.PixelFormats]::Pbgra32);$render.Render($viewport)
      $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($render))
      $stream=[IO.File]::Create((Join-Path $PreviewDirectory ('theme-'+$choice.name+'.png')));try{$encoder.Save($stream)}finally{$stream.Dispose()}
    }
  }
  Write-Output 'PASS: real WPF bubble/menu resources, manual theme updates, menu toggle, bitmap preservation, quota warning semantics and cache reuse'
}finally{if($script:characterThemeEditor){$script:characterThemeEditor.Close()};if($script:window){$script:window.Close()};[IO.Directory]::Delete($script:dataDir,$true)}
