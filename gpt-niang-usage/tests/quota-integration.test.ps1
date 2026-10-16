param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$script:appDir=Split-Path $TestRoot -Parent
foreach($module in @('quotes.ps1','quota-character.ps1','quota-mood.ps1')){. (Join-Path $script:appDir ('runtime\'+$module))}
foreach($module in @('quote-layout.ps1','color-theme.ps1')){
  . ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir ('runtime\'+$module)),[Text.Encoding]::UTF8)))
}
Initialize-WidgetQuoteLayouts $script:appDir
$source=[IO.File]::ReadAllText((Join-Path $script:appDir 'widget.ps1'),[Text.Encoding]::UTF8)
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($name in @('Reset-Label','Format-ResetTime','Format-ResetDisplay','Get-QuotaWindowLabel','Get-QuotaRows','Apply-Scene','Update-BubbleTooltip','Update-Quota','Test-GirlAlpha')){
  $definition=$ast.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq $name},$true)
  . ([ScriptBlock]::Create($definition.Extent.Text))
}
function Assert-Equal($Actual,$Expected,[string]$Message){if($Actual-cne $Expected){throw "$Message : expected '$Expected', got '$Actual'"}}
$script:dataDir=Join-Path $TestRoot ('quota-integration-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($script:dataDir)
$script:window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $script:appDir 'widget.xaml'),[Text.Encoding]::UTF8))
$script:window.Left=-32000;$script:window.Top=-32000;$script:window.Opacity=0;$script:window.Show()
$script:ui=@{}
foreach($name in @('Root','Bubble','Tail','TailNear','SceneText','QuotaText','QuoteText','BubbleShape','Girl','PressScale','FacingScale','TextFacingScale','Header','Refresh','MenuButton','Status','LiveDot','ShortRow','WeekRow','ShortLabel','WeekLabel','ShortUsed','ShortLeft','ShortReset','ShortBar','WeekUsed','WeekLeft','WeekReset','WeekBar')){$script:ui[$name]=$script:window.FindName($name)}
$script:quotaMood='normal';$script:quotaMoodAccount='test-account';$script:quotaActualMood='normal';$script:quotaPreview=$false
$script:status=$null;$script:statusStamp=0;$script:bubbleMode='quote';$script:collapsed=$false;$script:resetTimeMode='fixed';$script:sceneRevision=1
$script:colorMode='original'
function Set-Snapshot($Short,$Week){
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();$future=[Math]::Floor($now/1000)+3600
  $snapshot=@{ok=$true;queryOk=$true;observedAt=$now;accountKey='test-account';windows=@(@{minutes=300;used=100-$Short;remaining=$Short;resetsAt=$future},@{minutes=10080;used=100-$Week;remaining=$Week;resetsAt=$future})}
  [IO.File]::WriteAllText((Join-Path $script:dataDir 'status.json'),($snapshot|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
  $script:statusStamp=0;Update-Quota
}
function Add-QuotaInk($Drawing,[Windows.Media.Matrix]$Matrix){
  if($Drawing-is [Windows.Media.DrawingGroup]){
    if($Drawing.Transform){$next=$Drawing.Transform.Value;$next.Append($Matrix)}else{$next=$Matrix}
    foreach($child in $Drawing.Children){Add-QuotaInk $child $next}
  }elseif($Drawing-is [Windows.Media.GlyphRunDrawing]){
    $outline=$Drawing.GlyphRun.BuildGeometry();$outline.Transform=[Windows.Media.MatrixTransform]::new($Matrix)
    $script:quotaInk.Children.Add($outline)
  }
}
function Assert-QuotaInkClearance {
  $script:window.UpdateLayout()
  foreach($name in @('ShortLabel','ShortLeft','ShortReset','WeekLabel','WeekLeft','WeekReset')){
    $control=$script:ui[$name];$script:quotaInk=[Windows.Media.GeometryGroup]::new()
    Add-QuotaInk ([Windows.Media.VisualTreeHelper]::GetDrawing($control)) ([Windows.Media.Matrix]::Identity)
    if($script:quotaInk.Children.Count-eq 0){throw 'Quota glyph check requires actual visible text'}
    $origin=$control.TranslatePoint([Windows.Point]::new(0,0),$script:ui.Root)
    $x=$control.TranslatePoint([Windows.Point]::new(1,0),$script:ui.Root);$y=$control.TranslatePoint([Windows.Point]::new(0,1),$script:ui.Root)
    $script:quotaInk.Transform=[Windows.Media.MatrixTransform]::new([Windows.Media.Matrix]::new($x.X-$origin.X,$x.Y-$origin.Y,$y.X-$origin.X,$y.Y-$origin.Y,$origin.X,$origin.Y))
    $bounds=$script:quotaInk.Bounds
    if($bounds.Bottom-lt [Windows.Controls.Canvas]::GetTop($script:ui.Girl)){continue}
    for($y=[int][Math]::Floor($bounds.Top);$y-le [Math]::Ceiling($bounds.Bottom);$y++){
      for($x=[int][Math]::Floor($bounds.Left);$x-le [Math]::Ceiling($bounds.Right);$x++){
        $point=[Windows.Point]::new($x+0.5,$y+0.5)
        if($script:quotaInk.FillContains($point) -and (Test-GirlAlpha $point)){throw "Low sprite obscures visible quota glyphs: $name"}
      }
    }
  }
}
try{
  $normal='普通语录测试';$low='耗尽专属语录测试'
  $null=Save-WidgetQuotes $script:dataDir @($normal)
  $null=Save-WidgetQuotes $script:dataDir @($low) -LowQuota
  Set-WidgetQuotaCharacter 'normal';Initialize-WidgetColors
  $script:ui.QuoteText.Text=Get-WidgetBubbleQuote $script:dataDir;Fit-QuoteText;Apply-Scene
  foreach($edge in @(@{short=5;week=80;want='low'},@{short=80;week=5;want='low'},@{short=100;week=5;want='low'},@{short=5;week=100;want='low'},@{short=5.01;week=5.01;want='normal'},@{short=0;week=80;want='low'},@{short=75;week=0;want='low'},@{short=75;week=90;want='normal'})){
    Set-Snapshot $edge.short $edge.week
    Assert-Equal $script:quotaMood $edge.want 'Real status-file path switches mood'
    Assert-Equal $script:quotaCharacterState $edge.want 'Real status-file path switches visible sprite'
    $quote=if($edge.want-eq 'low'){$low}else{$normal}
    Assert-Equal $script:ui.QuoteText.Tag $quote 'Already-open quote changes without a click'
    Assert-Equal $script:ui.QuoteText.Text $quote 'Displayed quote uses the independent pool'
    Assert-Equal $script:bubbleTooltipText.Text $quote 'Copy text follows the visible quote'
    for($i=0;$i-lt 20;$i++){Assert-Equal (Get-WidgetBubbleQuote $script:dataDir) $quote 'Quote pool cannot leak between states'}
    foreach($overlay in @($script:widgetColors.halo,$script:widgetColors.tint)){
      Assert-Equal $overlay.Width $script:ui.Girl.Width 'Colour overlay follows sprite size'
      Assert-Equal ([Windows.Controls.Canvas]::GetTop($overlay)) ([Windows.Controls.Canvas]::GetTop($script:ui.Girl)) 'Colour overlay follows sprite position'
      Assert-Equal ([object]::ReferenceEquals($overlay.OpacityMask.ImageSource,$script:ui.Girl.Source)) $true 'Colour mask follows the active sprite'
    }
    # Original pointer filtering must match the image actually shown.
    $script:window.UpdateLayout()
    $size=$script:ui.Girl.Width;$left=[Windows.Controls.Canvas]::GetLeft($script:ui.Girl);$top=[Windows.Controls.Canvas]::GetTop($script:ui.Girl)
    $opaque=$false;$transparent=$false
    for($y=0;$y-lt 1254;$y+=48){for($x=0;$x-lt 1254;$x+=48){
      $point=$script:ui.Girl.TranslatePoint([Windows.Point]::new($size*($x+0.5)/1254,$size*($y+0.5)/1254),$script:ui.Root)
      $hit=Test-GirlAlpha $point
      Assert-Equal $hit ($script:alphaPixels[$y*$script:alphaStride+$x*4+3]-gt 10) ("Pointer hit map follows the active sprite: mood=$($edge.want) pixel=$x,$y logical=$size actual=$($script:ui.Girl.ActualWidth),$($script:ui.Girl.ActualHeight) bitmap=$($script:bitmap.PixelWidth),$($script:bitmap.PixelHeight)")
      if($hit){$opaque=$true}else{$transparent=$true}
    }}
    if(!$opaque -or !$transparent){throw 'Sprite alpha check did not cover both opaque and transparent points'}
  }
  Set-WidgetQuotaPreview $true
  Assert-Equal $script:ui.QuoteText.Tag $low 'Preview switches exclusive quotes'
  Set-Snapshot 100 5;Set-WidgetQuotaPreview $false
  Assert-Equal $script:ui.QuoteText.Tag $low 'Ending preview retains actual low weekly state'
  [IO.File]::WriteAllText((Join-Path $script:dataDir 'status.json'),'{broken',[Text.UTF8Encoding]::new($false))
  $script:statusStamp=0;Update-Quota
  Assert-Equal $script:quotaMood 'low' 'Malformed status file preserves last confirmed state'
  Assert-Equal $script:ui.QuoteText.Tag $low 'Malformed status file cannot mix quote states'
  Set-Snapshot 75 90
  Assert-Equal $script:ui.QuoteText.Tag $normal 'Fresh recovery restores normal open quote'
  $script:bubbleMode='quota';Apply-Scene
  foreach($scale in @(0.6,0.8,1,1.4,2.5)){
    foreach($side in @(-1,1)){
      $script:ui.FacingScale.ScaleX=$side;$script:ui.TextFacingScale.ScaleX=$side
      $size=378*$scale;$viewport=$script:window.Content
      $viewport.Measure([Windows.Size]::new($size,$size));$viewport.Arrange([Windows.Rect]::new(0,0,$size,$size));$viewport.UpdateLayout()
      Set-Snapshot 5 80
      Assert-Equal $script:ui.Girl.Width 228 'Scaling does not change logical low pose size'
      Assert-QuotaInkClearance
      Set-Snapshot 75 90
      Assert-Equal $script:ui.Girl.Width 208 'Recovery restores logical normal pose size'
    }
  }
  Write-Output 'PASS: upstream status-file -> actual WPF sprite and open/custom quotes, alpha hit map, colour masks, preview/read-failure recovery, both orientations and five scales'
}finally{
  $script:window.Close()
  $resolved=[IO.Path]::GetFullPath($script:dataDir);$allowed=[IO.Path]::GetFullPath($TestRoot).TrimEnd('\')+'\'
  if(!$resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture path'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
