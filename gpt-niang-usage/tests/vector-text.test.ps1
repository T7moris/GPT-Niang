param([string]$TestRoot=$PSScriptRoot,[switch]$Worker,[string]$MovedRoot)
$ErrorActionPreference='Stop'
$app=Split-Path $TestRoot -Parent
if(!$Worker){
  $moved=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-vector-'+[Guid]::NewGuid().ToString('N'))
  try{
    $fontDirectory=Join-Path $moved 'private [font & folder]\assets\fonts'
    $null=New-Item -ItemType Directory -Path $fontDirectory -Force
    Copy-Item -LiteralPath (Join-Path $app 'assets\fonts\LXGWWenKai-Medium.ttf') -Destination $fontDirectory
    $powerShell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $powerShell -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath -TestRoot $TestRoot -Worker -MovedRoot $moved
    if($LASTEXITCODE-ne 0){throw 'Vector rendering worker failed.'}
  }finally{
    # WPF releases its private-font file handles when the worker process exits.
    $resolved=[IO.Path]::GetFullPath($moved);$tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved)-notlike 'gpt-niang-vector-*'){throw 'Unsafe vector-test cleanup path.'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
  }
  return
}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
. (Join-Path $app 'runtime\sharp-text.ps1')
$xaml=[IO.File]::ReadAllText((Join-Path $app 'widget.xaml'),[Text.Encoding]::UTF8)
$moved=$MovedRoot
try{
  $fontDirectory=Join-Path $moved 'private [font & folder]\assets\fonts'
  $movedApp=Split-Path (Split-Path $fontDirectory -Parent) -Parent
  $window=[Windows.Markup.XamlReader]::Parse((ConvertTo-SmoothWidgetXaml $xaml -AppDir $movedApp))
  $header=$window.FindName('Header')
  $face=[Windows.Media.Typeface]::new($header.FontFamily,$header.FontStyle,$header.FontWeight,$header.FontStretch)
  $glyph=$null
  if(!$face.TryGetGlyphTypeface([ref]$glyph) -or ([Uri]::UnescapeDataString($glyph.FontUri.AbsoluteUri)).IndexOf('private [font & folder]',[StringComparison]::OrdinalIgnoreCase)-lt 0){throw 'Relocated private font was not loaded.'}
  $root=$window.FindName('Root');$menu=$window.FindName('MenuButton');$icon=$window.FindName('MenuIconLines')
  $menu.Opacity=1;$menu.IsHitTestVisible=$true
  $refresh=$window.FindName('Refresh')
  $hover=$refresh.Style.Triggers|Where-Object{$_-is [Windows.DataTrigger]}|Select-Object -First 1
  $probe=[Windows.Data.BindingOperations]::SetBinding($refresh,[Windows.FrameworkElement]::TagProperty,$hover.Binding)
  $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::DataBind)
  if($probe.DataItem-ne $window.FindName('Bubble') -or $refresh.Opacity-ne 0){throw 'Refresh hover binding or idle visibility is incorrect.'}
  $view=$window.Content;$window.Content=$null
  $frame=[Windows.Controls.Grid]::new();$frame.Resources=$window.Resources
  [Windows.Documents.TextElement]::SetFontFamily($frame,$window.FontFamily);[Windows.Documents.TextElement]::SetFontWeight($frame,$window.FontWeight)
  $frame.Children.Add($view)|Out-Null
  $lines=@($icon.Data.GetFlattenedPathGeometry().Figures)
  if($lines.Count-ne 3){throw 'Menu icon must use three vector lines.'}
  $checks=0
  foreach($scale in @(0.8,1.4,0.6,2.5,1.0,0.8)){
    foreach($facing in @(1,-1)){
      $window.FindName('FacingScale').ScaleX=$facing;$window.FindName('TextFacingScale').ScaleX=$facing
      $menu.RenderTransformOrigin=[Windows.Point]::new(.5,.5);$menu.RenderTransform=[Windows.Media.ScaleTransform]::new($facing,1)
      $side=378*$scale;$frame.Measure([Windows.Size]::new($side,$side));$frame.Arrange([Windows.Rect]::new(0,0,$side,$side));$frame.UpdateLayout()
      $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int][Math]::Ceiling($side),[int][Math]::Ceiling($side),96,96,[Windows.Media.PixelFormats]::Pbgra32)
      $bitmap.Render($frame)
      $drawing=[Windows.Media.VisualTreeHelper]::GetDrawing($header)
      if(!$drawing -or !@($drawing.Children|Where-Object{$_-is [Windows.Media.GeometryDrawing]}).Count){throw 'Text must render vector geometry rather than a resized text bitmap.'}
      $transform=$icon.TransformToAncestor($frame);$ys=@();$widths=@()
      foreach($line in $lines){
        $segment=$line.Segments[0];$end=if($segment-is [Windows.Media.LineSegment]){$segment.Point}else{$segment.Points[0]}
        $a=$transform.Transform($line.StartPoint);$b=$transform.Transform($end)
        if([Math]::Abs($a.Y-$b.Y)-gt .0001){throw 'Menu line tilted after resizing.'}
        $ys+=$a.Y;$widths+=[Math]::Abs($b.X-$a.X)
      }
      if([Math]::Abs(($ys[1]-$ys[0])-($ys[2]-$ys[1]))-gt .0001 -or [Math]::Abs($widths[0]-$widths[2])-gt .0001){throw 'Menu spacing or line length changed after resizing.'}
      $buttonPosition=$refresh.TranslatePoint([Windows.Point]::new(0,0),$root)
      $interior=[Windows.Media.EllipseGeometry]::new([Windows.Point]::new(155,85),124,75)
      $buttonBox=[Windows.Media.RectangleGeometry]::new([Windows.Rect]::new($buttonPosition.X,$buttonPosition.Y,$refresh.ActualWidth,$refresh.ActualHeight))
      if($interior.FillContainsWithDetail($buttonBox)-ne [Windows.Media.IntersectionDetail]::FullyContains){throw 'Refresh button left the bubble interior.'}
      $checks++
    }
  }
  Write-Output "PASS: relocated font with escaped paths, vector text drawings, refresh hover binding and $checks repeated icon scaling/orientation checks"
}finally{
  if($window){$window.Close()}
}
