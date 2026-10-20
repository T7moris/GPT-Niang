param([string]$PreviewDirectory,[string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$appDir=Split-Path $TestRoot -Parent
$xaml=[IO.File]::ReadAllText((Join-Path $appDir 'widget.xaml'),[Text.Encoding]::UTF8)

function Render-CharacterScene($Source,[double]$Scale=0.6,[double]$DpiScale=1,[switch]$Before){
  $window=[Windows.Markup.XamlReader]::Parse($xaml)
  try{
    $girl=$window.FindName('Girl');$girl.Source=$Source
    foreach($name in @('Bubble','Tail','TailNear','MenuButton')){$window.FindName($name).Visibility=[Windows.Visibility]::Hidden}
    if($Before){
      [Windows.Media.RenderOptions]::SetBitmapScalingMode($window.FindName('ScaleHost'),[Windows.Media.BitmapScalingMode]::LowQuality)
      [Windows.Media.RenderOptions]::SetBitmapScalingMode($girl,[Windows.Media.BitmapScalingMode]::LowQuality)
    }
    $dipSize=378*$Scale;$pixelSize=[int][Math]::Ceiling($dipSize*$DpiScale)
    $viewport=$window.Content
    $viewport.Measure([Windows.Size]::new($dipSize,$dipSize))
    $viewport.Arrange([Windows.Rect]::new(0,0,$dipSize,$dipSize));$viewport.UpdateLayout()
    $script:lastCharacterSlotCenter=$girl.TranslatePoint([Windows.Point]::new($girl.ActualWidth/2,$girl.ActualHeight/2),$viewport)
    $render=[Windows.Media.Imaging.RenderTargetBitmap]::new($pixelSize,$pixelSize,96*$DpiScale,96*$DpiScale,[Windows.Media.PixelFormats]::Pbgra32)
    $render.Render($viewport);$render.Freeze();return $render
  }finally{$window.Close()}
}
function Get-ImagePixels($Image){
  $pixels=New-Object byte[] ($Image.PixelWidth*$Image.PixelHeight*4)
  $Image.CopyPixels($pixels,$Image.PixelWidth*4,0)
  return ,$pixels
}
function Get-AlphaBounds($Image){
  $pixels=Get-ImagePixels $Image
  $left=$Image.PixelWidth;$top=$Image.PixelHeight;$right=-1;$bottom=-1
  for($y=0;$y-lt $Image.PixelHeight;$y++){
    for($x=0;$x-lt $Image.PixelWidth;$x++){
      if($pixels[($y*$Image.PixelWidth+$x)*4+3]-lt 200){continue}
      $left=[Math]::Min($left,$x);$right=[Math]::Max($right,$x)
      $top=[Math]::Min($top,$y);$bottom=[Math]::Max($bottom,$y)
    }
  }
  if($right-lt 0){throw 'Character did not render'}
  return [pscustomobject]@{Left=$left;Top=$top;Right=$right;Bottom=$bottom;Width=$right-$left+1;Height=$bottom-$top+1}
}
function New-SolidCharacter([int]$Width,[int]$Height){
  $pixels=New-Object byte[] ($Width*$Height*4)
  for($i=0;$i-lt $pixels.Length;$i+=4){$pixels[$i+2]=255;$pixels[$i+3]=255}
  $bitmap=[Windows.Media.Imaging.BitmapSource]::Create($Width,$Height,96,96,[Windows.Media.PixelFormats]::Bgra32,$null,$pixels,$Width*4)
  $bitmap.Freeze();return $bitmap
}
function Save-Image($Image,[string]$Path){
  $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new()
  $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($Image))
  $stream=[IO.File]::Create($Path)
  try{$encoder.Save($stream)}finally{$stream.Dispose()}
}
function Get-EdgeMetrics($Image){
  $pixels=Get-ImagePixels $Image;$fractional=0;$strongSteps=0
  for($i=3;$i-lt $pixels.Length;$i+=4){
    $alpha=[int]$pixels[$i]
    if($alpha-ge 8 -and $alpha-le 245){$fractional++}
    if((($i-3)/4)%$Image.PixelWidth-ne 0 -and [Math]::Abs($alpha-[int]$pixels[$i-4])-gt 128){$strongSteps++}
  }
  return [pscustomobject]@{FractionalEdges=$fractional;StrongHorizontalSteps=$strongSteps}
}

$bitmap=[Windows.Media.Imaging.BitmapImage]::new([Uri](Join-Path $appDir 'assets\gpt-dragon-niang-bust.png'));$bitmap.Freeze()
$before=Render-CharacterScene $bitmap -Before
$after=Render-CharacterScene $bitmap
$beforePixels=Get-ImagePixels $before;$afterPixels=Get-ImagePixels $after;$changed=0
for($i=0;$i-lt $beforePixels.Length;$i++){if($beforePixels[$i]-ne $afterPixels[$i]){$changed++}}
$beforeEdges=Get-EdgeMetrics $before;$afterEdges=Get-EdgeMetrics $after
if($changed-lt 100){throw 'High quality sampling does not affect the actual small character render'}
if($afterEdges.FractionalEdges-lt 1.5*$beforeEdges.FractionalEdges){throw 'Downscaled character lost smooth fractional-alpha edge coverage'}
if($afterEdges.StrongHorizontalSteps-ge $beforeEdges.StrongHorizontalSteps){throw 'Downscaled character still has as many abrupt alpha steps as low quality sampling'}
if($afterPixels[3]-ne 0){throw 'Transparent widget margin became opaque'}
Write-Output ('PASS: actual 60% WPF render: changed channels {0}; fractional edge coverage {1}->{2}; abrupt horizontal alpha steps {3}->{4}' -f $changed,$beforeEdges.FractionalEdges,$afterEdges.FractionalEdges,$beforeEdges.StrongHorizontalSteps,$afterEdges.StrongHorizontalSteps)

$wide=New-SolidCharacter 240 120;$tall=New-SolidCharacter 120 240;$cases=0
foreach($scale in @(0.6,0.8,1.4)){
  foreach($dpi in @(1,1.25,1.5,2)){
    foreach($shape in @(@{name='wide';source=$wide;width=208;height=104},@{name='tall';source=$tall;width=104;height=208})){
      $image=Render-CharacterScene $shape.source $scale $dpi;$bounds=Get-AlphaBounds $image
      $factor=$scale*$dpi;$expectedWidth=$shape.width*$factor;$expectedHeight=$shape.height*$factor
      if([Math]::Abs($bounds.Width-$expectedWidth)-gt 2 -or [Math]::Abs($bounds.Height-$expectedHeight)-gt 2){throw ('{0} character is cropped or stretched at scale {1}, DPI {2}: {3}x{4}' -f $shape.name,$scale,$dpi,$bounds.Width,$bounds.Height)}
      # WPF rounds layout in device units; compare the rendered pixels with the
      # measured image slot rather than an ideal, unrounded Viewbox coordinate.
      $expectedCenter=$script:lastCharacterSlotCenter
      if([Math]::Abs(($bounds.Left+$bounds.Right+1)/2-$expectedCenter.X*$dpi)-gt 2 -or [Math]::Abs(($bounds.Top+$bounds.Bottom+1)/2-$expectedCenter.Y*$dpi)-gt 2){throw ('{0} character is not centered inside the measured image slot at scale {1}, DPI {2}' -f $shape.name,$scale,$dpi)}
      $cases++
    }
  }
}
Write-Output ('PASS: {0} real WPF renders preserve wide/tall aspect ratio and transparent letterboxing at 60%, 80%, 140% and 100%, 125%, 150%, 200% DPI' -f $cases)

if($PreviewDirectory){
  $null=New-Item -ItemType Directory -Path $PreviewDirectory -Force
  Save-Image $before (Join-Path $PreviewDirectory 'character-60-before.png')
  Save-Image $after (Join-Path $PreviewDirectory 'character-60-high-quality.png')
  $crop=[Windows.Int32Rect]::new(92,92,128,128)
  $beforeCrop=[Windows.Media.Imaging.CroppedBitmap]::new($before,$crop)
  $afterCrop=[Windows.Media.Imaging.CroppedBitmap]::new($after,$crop)
  $visual=[Windows.Media.DrawingVisual]::new();$drawing=$visual.RenderOpen()
  try{
    $drawing.DrawRectangle([Windows.Media.Brushes]::White,$null,[Windows.Rect]::new(0,0,680,430))
    $typeface=[Windows.Media.Typeface]::new('Segoe UI')
    foreach($label in @(@{text='60% - before';x=20},@{text='60% - high quality';x=355})){
      $text=[Windows.Media.FormattedText]::new($label.text,[Globalization.CultureInfo]::InvariantCulture,[Windows.FlowDirection]::LeftToRight,$typeface,20,[Windows.Media.Brushes]::Black)
      $drawing.DrawText($text,[Windows.Point]::new($label.x,12))
    }
    # Keep the native 128 px character crop at the top; magnify its rendered pixels below.
    $drawing.DrawImage($beforeCrop,[Windows.Rect]::new(105,45,128,128))
    $drawing.DrawImage($afterCrop,[Windows.Rect]::new(440,45,128,128))
    $drawing.DrawImage($beforeCrop,[Windows.Rect]::new(42,180,256,256))
    $drawing.DrawImage($afterCrop,[Windows.Rect]::new(377,180,256,256))
  }finally{$drawing.Close()}
  [Windows.Media.RenderOptions]::SetBitmapScalingMode($visual,[Windows.Media.BitmapScalingMode]::NearestNeighbor)
  $comparison=[Windows.Media.Imaging.RenderTargetBitmap]::new(680,440,96,96,[Windows.Media.PixelFormats]::Pbgra32);$comparison.Render($visual)
  Save-Image $comparison (Join-Path $PreviewDirectory 'character-60-comparison.png')
  Write-Output ('PREVIEW: '+(Join-Path $PreviewDirectory 'character-60-comparison.png'))
}
