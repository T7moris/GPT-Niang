param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$app=Split-Path $TestRoot -Parent
. (Join-Path $app 'runtime\sharp-text.ps1')
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $app 'runtime\quote-layout.ps1'),[Text.Encoding]::UTF8)))
Initialize-WidgetQuoteLayouts $app
$script:window=[Windows.Markup.XamlReader]::Parse((ConvertTo-SmoothWidgetXaml ([IO.File]::ReadAllText((Join-Path $app 'widget.xaml'),[Text.Encoding]::UTF8)) -AppDir $app))
$script:ui=@{}
foreach($name in @('Root','SceneText','QuoteText','QuotaText','Refresh','FacingScale','TextFacingScale','ShortRow','WeekRow')){$script:ui[$name]=$script:window.FindName($name)}
$script:ui.QuotaText.Visibility=[Windows.Visibility]::Collapsed
$script:ui.Refresh.Visibility=[Windows.Visibility]::Collapsed
$script:ui.QuoteText.Visibility=[Windows.Visibility]::Visible
$script:bubbleMode='quote'
$profiles=Get-Content -LiteralPath (Join-Path $app 'assets\quote-layouts.json') -Raw -Encoding UTF8|ConvertFrom-Json
. (Join-Path $app 'runtime\quotes.ps1')
$freshData=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-quotes-'+[Guid]::NewGuid().ToString('N'))
$defaults=Get-WidgetQuoteSettings $freshData
if($defaults.source-ne 'built-in' -or $defaults.error){throw 'A fresh installation must load the bundled quote pool'}
foreach($row in $defaults.quotes){if(!$script:quoteLayoutMap.ContainsKey($row.text)){throw ('Bundled quote lacks a reviewed layout: '+$row.text)}}
$values=@($defaults.quotes.text)+@('好模型',('自定义测试' * 40))
function Add-QuoteInk($drawing,[Windows.Media.Matrix]$matrix){
  if($drawing-is [Windows.Media.DrawingGroup]){
    if($drawing.Transform){$next=$drawing.Transform.Value;$next.Append($matrix)}else{$next=$matrix}
    foreach($child in $drawing.Children){Add-QuoteInk $child $next}
  }elseif($drawing-is [Windows.Media.GlyphRunDrawing]){
    $outline=$drawing.GlyphRun.BuildGeometry();$outline.Transform=[Windows.Media.MatrixTransform]::new($matrix)
    $script:quoteInk.Children.Add($outline)
  }elseif($drawing-is [Windows.Media.GeometryDrawing]){
    $outline=$drawing.Geometry.Clone();$outline.Transform=[Windows.Media.MatrixTransform]::new($matrix)
    $script:quoteInk.Children.Add($outline)
  }
}
function Assert-QuoteLayout([string]$original,[double]$scale){
  $viewport=$script:window.Content;$size=350*$scale
  $viewport.Measure([Windows.Size]::new($size,$size));$viewport.Arrange([Windows.Rect]::new(0,0,$size,$size));$viewport.UpdateLayout()
  if(($script:ui.QuoteText.Text-replace '\s','')-cne ($original-replace '\s','') -or $script:ui.QuoteText.Tag-cne $original){throw 'Quote content or canonical identity changed'}
  $script:quoteInk=[Windows.Media.GeometryGroup]::new()
  Add-QuoteInk ([Windows.Media.VisualTreeHelper]::GetDrawing($script:ui.QuoteText)) ([Windows.Media.Matrix]::Identity)
  $origin=$script:ui.QuoteText.TranslatePoint([Windows.Point]::new(0,0),$script:ui.Root)
  $x=$script:ui.QuoteText.TranslatePoint([Windows.Point]::new(1,0),$script:ui.Root)
  $y=$script:ui.QuoteText.TranslatePoint([Windows.Point]::new(0,1),$script:ui.Root)
  $matrix=[Windows.Media.Matrix]::new($x.X-$origin.X,$x.Y-$origin.Y,$y.X-$origin.X,$y.Y-$origin.Y,$origin.X,$origin.Y)
  $script:quoteInk.Transform=[Windows.Media.MatrixTransform]::new($matrix)
  $safe=[Windows.Media.EllipseGeometry]::new([Windows.Point]::new(155,85),118,69)
  if($script:quoteInk.Children.Count-eq 0 -or $safe.FillContainsWithDetail($script:quoteInk)-ne [Windows.Media.IntersectionDetail]::FullyContains){throw ('Actual rendered glyphs escaped the ellipse: '+$original)}
  $ink=$script:quoteInk.Bounds
  if([Math]::Abs($ink.Left+$ink.Width/2-155)-gt 3 -or [Math]::Abs($ink.Top+$ink.Height/2-85)-gt 3){throw ('Quote is not optically centered: '+$original)}
}
try{
  $checks=0
  foreach($value in $values){
    $script:ui.QuoteText.Text=$value;Fit-QuoteText;Set-WidgetSceneLayout
    $cached=$script:quoteLayout
    if($script:quoteLayoutMap.ContainsKey($value) -and $cached.fontSize-lt 20){throw ('Reviewed quote became too small: '+$value)}
    foreach($facing in @(1,-1)){
      $script:ui.FacingScale.ScaleX=$facing;$script:ui.TextFacingScale.ScaleX=$facing
      foreach($scale in @(0.6,1,1.4,2.5)){Assert-QuoteLayout $value $scale;$checks++}
    }
    if(![object]::ReferenceEquals($cached,(Get-WidgetQuoteLayout $script:ui.QuoteText.Text $script:ui.QuoteText))){throw 'Repeated layout did not use the cache'}
  }
  $script:bubbleMode='quota';Set-WidgetSceneLayout
  if([Windows.Controls.Canvas]::GetLeft($script:ui.SceneText)-ne 47 -or [Windows.Controls.Canvas]::GetTop($script:ui.SceneText)-ne 18 -or $script:ui.SceneText.Width-ne 216 -or $script:ui.SceneText.Height-ne 118){throw 'Switching back to quota did not restore its layout'}
  Write-Output ('PASS: '+$profiles.quotes.Count+' reviewed quotes, short and 200-character custom quotes; '+$checks+' native glyph checks across both orientations and four scales; quota restoration and layout cache')
}finally{$script:window.Close()}
