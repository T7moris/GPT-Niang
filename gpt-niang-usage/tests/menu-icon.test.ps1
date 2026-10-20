param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$appDir=Split-Path $TestRoot -Parent
$window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $appDir 'widget.xaml'),[Text.Encoding]::UTF8))
try{
  $menu=$window.FindName('MenuButton');$icon=$window.FindName('MenuIconLines');$menu.Opacity=1;$menu.IsHitTestVisible=$true
  if(!$icon){throw 'Vector menu icon is absent'}
  $view=$window.Content;$window.Content=$null
  $frame=[Windows.Controls.Grid]::new();$frame.Resources=$window.Resources;$frame.Children.Add($view)|Out-Null
  $lines=@($icon.Data.GetFlattenedPathGeometry().Figures)
  if($lines.Count-ne 3){throw 'Menu icon must contain three lines'}
  $checks=0
  foreach($scale in @(0.6,0.8,1,1.4,2.5)){
    foreach($facing in @(1,-1)){
      $window.FindName('FacingScale').ScaleX=$facing
      $menu.RenderTransformOrigin=[Windows.Point]::new(.5,.5);$menu.RenderTransform=[Windows.Media.ScaleTransform]::new($facing,1)
      $side=378*$scale;$frame.Measure([Windows.Size]::new($side,$side));$frame.Arrange([Windows.Rect]::new(0,0,$side,$side));$frame.UpdateLayout()
      $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int][Math]::Ceiling($side),[int][Math]::Ceiling($side),96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($frame)
      $transform=$icon.TransformToAncestor($frame);$ys=@();$widths=@()
      foreach($line in $lines){
        $segment=$line.Segments[0];$end=if($segment-is [Windows.Media.LineSegment]){$segment.Point}else{$segment.Points[0]}
        $a=$transform.Transform($line.StartPoint);$b=$transform.Transform($end)
        if([Math]::Abs($a.Y-$b.Y)-gt .0001){throw 'Menu line tilts after scaling or mirroring'}
        $ys+=$a.Y;$widths+=[Math]::Abs($a.X-$b.X)
      }
      if([Math]::Abs(($ys[1]-$ys[0])-($ys[2]-$ys[1]))-gt .0001 -or [Math]::Abs($widths[0]-$widths[2])-gt .0001){throw 'Menu line lengths or spacing changed'}
      $checks++
    }
  }
  Write-Output "PASS: $checks actual WPF renders retain horizontal, equally spaced vector menu lines in both orientations at 60%-250%"
}finally{$window.Close()}
