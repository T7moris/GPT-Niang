param([string]$TestRoot=$PSScriptRoot,[string]$PreviewDirectory)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$appDir=Split-Path $TestRoot -Parent
. (Join-Path $appDir 'runtime\sharp-text.ps1')
$source=[IO.File]::ReadAllText((Join-Path $appDir 'widget.ps1'),[Text.Encoding]::UTF8)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($name in @('Get-WidgetLayoutScale','Set-WidgetIndependentLayout','Get-QuotaRows','Get-QuotaWindowLabel','Test-GirlAlpha','Set-Appearance','Set-Facing','Write-WidgetJson','Save-Settings','Set-WidgetPixelSize','Test-WidgetPlacementFrame')){
  $definition=$ast.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq $name},$true)
  . ([ScriptBlock]::Create($definition.Extent.Text))
}
# WPF rounds design coordinates before the Viewbox applies up to 2.5x zoom.
function Assert-Near([double]$Actual,[double]$Expected,[string]$Message){if([Math]::Abs($Actual-$Expected)-gt 1.5){throw "$Message : expected $Expected, got $Actual"}}
$script:window=[Windows.Markup.XamlReader]::Parse((ConvertTo-SmoothWidgetXaml ([IO.File]::ReadAllText((Join-Path $appDir 'widget.xaml'),[Text.Encoding]::UTF8)) -AppDir $appDir))
$script:ui=@{}
foreach($name in @('Root','Girl','Bubble','BubbleShape','Tail','TailNear','MenuButton','Refresh','SceneText','FacingScale','TextFacingScale','Header','QuoteText','ShortLeft','WeekLeft','ShortBar','WeekBar')){$script:ui[$name]=$script:window.FindName($name)}
$script:ui.Girl.Source=[Windows.Media.Imaging.BitmapImage]::new([Uri](Join-Path $appDir 'assets\gpt-dragon-niang-bust.png'))
$script:hostHandle=[IntPtr]::Zero;$script:followHost=$true;$script:side='right'
$script:designWidth=[double]$script:window.FindName('AnimationStage').Width
$script:designHeight=[double]$script:window.FindName('AnimationStage').Height
function Get-WidgetPlacementDpi {return 1.0}
$script:status=$null;$script:collapsed=$false;$script:bubbleMode='quota';$script:characterId='kept-character';$script:soundVolume=0.37
$script:dataDir=Join-Path $TestRoot 'unused-independent-colors'
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $appDir 'runtime\color-theme.ps1'),[Text.Encoding]::UTF8)))
function Layout-Widget {
  Set-Appearance
  $script:window.Content.Measure([Windows.Size]::new($script:window.Width,$script:window.Height))
  $script:window.Content.Arrange([Windows.Rect]::new(0,0,$script:window.Width,$script:window.Height))
  $script:window.Content.UpdateLayout()
}
function Width-InViewport($Control){
  $a=$Control.TranslatePoint([Windows.Point]::new(0,0),$script:window.Content)
  $b=$Control.TranslatePoint([Windows.Point]::new($Control.ActualWidth,0),$script:window.Content)
  return [Math]::Abs($b.X-$a.X)
}
function Save-Preview([string]$Name){
  if(!$PreviewDirectory){return}
  New-Item -ItemType Directory -Path $PreviewDirectory -Force|Out-Null
  $size=[int][Math]::Ceiling($script:window.Width)
  $image=[Windows.Media.Imaging.RenderTargetBitmap]::new($size,$size,96,96,[Windows.Media.PixelFormats]::Pbgra32)
  $image.Render($script:window.Content)
  $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($image))
  $stream=[IO.File]::Create((Join-Path $PreviewDirectory ($Name+'.png')))
  try{$encoder.Save($stream)}finally{$stream.Dispose()}
}
try{
  $script:scale=0.6;$script:bubbleScale=1.0
  Layout-Widget
  Assert-Near (Width-InViewport $script:ui.SceneText) 216 'Shrinking the character must keep a 100% bubble readable'
  Assert-Near (Width-InViewport $script:ui.Girl) (208*0.6) 'Character independently becomes 60%'
  Save-Preview 'character-60-bubble-100'
  Initialize-WidgetColors
  $script:bubbleScale=1.4;Layout-Widget
  Assert-Near (Width-InViewport $script:ui.SceneText) (216*1.4) 'Bubble grows independently'
  Assert-Near (Width-InViewport $script:ui.Girl) (208*0.6) 'Growing the bubble does not grow the character'
  Save-Preview 'character-60-bubble-140'
  foreach($character in @(0.6,0.8,1,1.4,2.5)){
    foreach($bubble in @(0.6,1,1.4,2.5)){
      foreach($side in @('left','right')){
        $script:scale=$character;$script:bubbleScale=$bubble;$script:side=$side;Layout-Widget
        Assert-Near (Width-InViewport $script:ui.Girl) (208*$character) 'Character size holds on either side'
        Assert-Near (Width-InViewport $script:ui.SceneText) (216*$bubble) 'Bubble size holds on either side'
        foreach($name in @('halo','tint')){
          $overlay=$script:widgetColors[$name]
          Assert-Near $overlay.Width $script:ui.Girl.Width 'Character color width must follow the current size'
          Assert-Near $overlay.Height $script:ui.Girl.Height 'Character color height must follow the current size'
          Assert-Near ([Windows.Controls.Canvas]::GetLeft($overlay)) ([Windows.Controls.Canvas]::GetLeft($script:ui.Girl)) 'Color layer left follows the character'
          Assert-Near ([Windows.Controls.Canvas]::GetTop($overlay)) ([Windows.Controls.Canvas]::GetTop($script:ui.Girl)) 'Color layer top follows the character'
        }
        $refreshCenter=$script:ui.Refresh.TranslatePoint([Windows.Point]::new($script:ui.Refresh.ActualWidth/2,$script:ui.Refresh.ActualHeight/2),$script:ui.Bubble)
        if(!$script:ui.BubbleShape.Data.FillContains($refreshCenter)){throw 'Refresh button escaped the actual bubble shape'}
        $icon=$script:ui.MenuButton.Content
        Assert-Near $icon.Width (14*$character/[Math]::Max([double]$character,[double]$bubble)) 'Menu icon must follow its independently scaled button'
        $textBottom=$script:ui.SceneText.TranslatePoint([Windows.Point]::new(0,$script:ui.SceneText.ActualHeight),$script:ui.Root).Y
        $girlTop=$script:ui.Girl.TranslatePoint([Windows.Point]::new(0,0),$script:ui.Root).Y
        if($textBottom-gt $girlTop){throw 'Quota text overlaps the character'}
        foreach($name in @('Girl','SceneText','Tail','TailNear')){
          $element=$script:ui[$name]
          $a=$element.TranslatePoint([Windows.Point]::new(0,0),$script:window.Content)
          $b=$element.TranslatePoint([Windows.Point]::new($element.ActualWidth,$element.ActualHeight),$script:window.Content)
          if([Math]::Min($a.X,$b.X)-lt -0.1 -or $a.Y-lt -0.1 -or [Math]::Max($a.X,$b.X)-gt $script:window.Width+0.1 -or $b.Y-gt $script:window.Height+0.1){throw "$name is clipped at character=$character bubble=$bubble side=$side : $a to $b inside $($script:window.Width) scale=$script:scale bubbleScale=$script:bubbleScale display=$script:displayScale top=$([Windows.Controls.Canvas]::GetTop($script:ui.Bubble))"}
        }
      }
    }
  }
  # Synthetic wide/tall alpha images exercise the production click mapping.
  $hitChecks=0
  foreach($shape in @(@{width=192;height=96},@{width=96;height=192},@{width=96;height=96})){
    $pixels=New-Object byte[] ($shape.width*$shape.height*4)
    for($y=0;$y-lt $shape.height;$y++){for($x=0;$x-lt $shape.width;$x++){
      $at=($y*$shape.width+$x)*4
      $pixels[$at]=120;$pixels[$at+1]=180;$pixels[$at+2]=220
      if($x-ge 8 -and $x-lt $shape.width-8 -and $y-ge 8 -and $y-lt $shape.height-8){$pixels[$at+3]=255}
    }}
    $script:bitmap=[Windows.Media.Imaging.BitmapSource]::Create($shape.width,$shape.height,96,96,[Windows.Media.PixelFormats]::Bgra32,$null,$pixels,$shape.width*4)
    $script:alphaStride=$shape.width*4;$script:alphaPixels=$pixels;$script:ui.Girl.Source=$script:bitmap
    foreach($character in @(0.6,1.4)){
      foreach($bubble in @(0.6,1.0,2.5)){
        foreach($side in @('left','right')){
          $script:scale=$character;$script:bubbleScale=$bubble;$script:side=$side;Layout-Widget
          $center=$script:ui.Girl.TranslatePoint([Windows.Point]::new($script:ui.Girl.ActualWidth/2,$script:ui.Girl.ActualHeight/2),$script:ui.Root)
          $corner=$script:ui.Girl.TranslatePoint([Windows.Point]::new(0.1,0.1),$script:ui.Root)
          if(!(Test-GirlAlpha $center) -or (Test-GirlAlpha $corner)){throw 'Independent sizing changed opaque/transparent image hit detection'}
          $hitChecks++
        }
      }
    }
  }
  # Fit small work areas without overwriting the requested sizes.
  $script:scale=2.5;$script:bubbleScale=0.6;$script:followHost=$false
  function Get-WidgetPlacementFrame {return [pscustomobject]@{Left=0;Top=0;Right=640;Bottom=480}}
  Layout-Widget
  if($script:window.Width-gt 640.01 -or $script:window.Height-gt 480.01 -or $script:scale-ne 2.5 -or $script:bubbleScale-ne 0.6){throw 'Work-area fitting clipped the stage or changed requested sizes'}
  $script:followHost=$true;Layout-Widget
  Assert-Near $script:displayScale 2.5 'Restored work area recovers the requested sizes'
  $settingsFile=Join-Path $TestRoot 'independent-size.settings.tmp.json'
  $script:scale=0.6;$script:bubbleScale=1.0;Save-Settings
  $saved=Get-Content -LiteralPath $settingsFile -Raw|ConvertFrom-Json
  if($saved.scale-ne 0.6 -or $saved.bubbleScale-ne 1 -or $saved.characterId-ne 'kept-character' -or $saved.soundVolume-ne 0.37){throw 'Independent size preferences were not saved accurately'}
  Write-Output ('PASS: '+$hitChecks+' custom-image alpha hit cases; color overlay and refresh alignment; small-window fitting; existing character and volume settings')
  Write-Output 'PASS: independent character/bubble sizes, 40 size/side combinations, readable text, bounds and persistence'
}finally{$script:window.Close();if($settingsFile -and (Test-Path -LiteralPath $settingsFile)){Remove-Item -LiteralPath $settingsFile}}
