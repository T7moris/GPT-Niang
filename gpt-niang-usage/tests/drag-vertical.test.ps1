param([string]$WidgetSource,[string]$ResultFile)
$ErrorActionPreference='Stop';$app=Split-Path $PSScriptRoot -Parent
if(!$WidgetSource){$WidgetSource=Join-Path $app 'widget.ps1'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
. (Join-Path $app 'runtime\sharp-text.ps1')
$text=[IO.File]::ReadAllText($WidgetSource,[Text.Encoding]::UTF8);$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Widget source did not parse'}
foreach($name in @('Set-Facing','Set-WidgetPixelSize','Get-WidgetLayoutScale','Set-WidgetIndependentLayout','Test-WidgetPlacementFrame','Set-Appearance','Limit-WidgetVerticalPosition','Limit-WidgetHorizontalPosition')){
 $f=$ast.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq $name},$true)
 if($f){. ([ScriptBlock]::Create($f.Extent.Text))}
}
$f=$ast.Find({param($n)$n-is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text-eq '$pressMove'},$true)
$body=$f.Right.Extent.Text.Trim();$pressMove=[ScriptBlock]::Create($body.Substring(1,$body.Length-2))
$tick=$ast.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq 'Tick-Widget'},$true).Extent.Text
$start=$tick.IndexOf('      $w=[int]($script:designWidth*');$end=$tick.IndexOf('      $position=', $start)
if($start-lt 0 -or $end-lt 0){throw 'Missing placement block'}
$place=[ScriptBlock]::Create($tick.Substring($start,$end-$start))
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class GptWidgetNative {
 public struct Point{public int X,Y;}public struct Rect{public int Left,Top,Right,Bottom;}
 public static int X,Y;
 public static bool GetCursorPos(out Point p){p=new Point{X=X,Y=Y};return true;}
 [DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")]public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
 [DllImport("user32.dll")]public static extern bool SetWindowPos(IntPtr h,IntPtr a,int x,int y,int w,int ht,uint f);
}
'@
$previousDpiContext=[GptWidgetNative]::SetThreadDpiAwarenessContext([IntPtr](-4))
function Get-WidgetPlacementFrame {return $script:frame}
function Get-WidgetPlacementDpi {return $script:testDpi}
function Sync-WidgetCharacterColors {}
function Test-WidgetMusicActive {return $false}
function Pump-Layout {
 $queue=[Windows.Threading.DispatcherFrame]::new();$timer=[Windows.Threading.DispatcherTimer]::new()
 $timer.Interval=[TimeSpan]::FromMilliseconds(16)
 $handler={param($sender,$event)$sender.Stop();$queue.Continue=$false}.GetNewClosure()
 $timer.Add_Tick($handler);$timer.Start();[Windows.Threading.Dispatcher]::PushFrame($queue);$timer.Remove_Tick($handler)
}
$script:hostHandle=[IntPtr](1);$script:designWidth=$script:designHeight=378
$script:hostEventTimer=$null;$script:widgetMusic=$null;$window=$null;$cases=0;$samples=0;$releaseChecks=0;$maxError=0.0
try{
 $window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $app 'widget.xaml'),[Text.Encoding]::UTF8))
 $window.Left=-9000;$window.Top=-9000;$window.ShowActivated=$false;$script:window=$window;$script:ui=@{}
 foreach($name in @('Root','Girl','Bubble','Tail','TailNear','MenuButton','Refresh','FacingScale','TextFacingScale','PressScale')){$script:ui[$name]=$window.FindName($name)}
 $script:ui.Girl.Source=[Windows.Media.Imaging.BitmapImage]::new([Uri](Join-Path $app 'assets/gpt-dragon-niang-bust.png'))
 $window.Show();$script:widgetHandle=[Windows.Interop.WindowInteropHelper]::new($window).Handle
 foreach($follow in @($true,$false)){
  foreach($dpi in @(1.0,1.5,2.0)){
   foreach($character in @(.6,1.0,2.5)){
    foreach($bubble in @(.6,1.0,2.5)){
     foreach($side in @('left','right')){
      $script:followHost=$follow;$script:testDpi=$dpi;$script:scale=$character;$script:bubbleScale=$bubble;$script:side=$side
      $zoom=[Math]::Max($character,$bubble)
      $script:frame=[pscustomobject]@{Left=-9000;Top=-9000;Right=(-9000+[int](2200*$zoom*$dpi));Bottom=(-9000+[int](1300*$zoom*$dpi))}
      Set-Appearance;Pump-Layout
      $window.Content.Measure([Windows.Size]::new($window.Width,$window.Height))
      $window.Content.Arrange([Windows.Rect]::new(0,0,$window.Width,$window.Height));$window.Content.UpdateLayout()
      $originX=if($side-eq 'left'){$script:frame.Left+100*$dpi}else{$script:frame.Right-$window.Width-100*$dpi}
      [GptWidgetNative]::SetWindowPos($script:widgetHandle,[IntPtr]::Zero,[int]$originX,[int]($script:frame.Top+250*$zoom*$dpi),0,0,0x15)|Out-Null
      $rect=New-Object GptWidgetNative+Rect;[GptWidgetNative]::GetWindowRect($script:widgetHandle,[ref]$rect)|Out-Null
      $start=$script:ui.Girl.PointToScreen([Windows.Point]::new(0,0));$bottom=$script:ui.Girl.PointToScreen([Windows.Point]::new(0,$script:ui.Girl.ActualHeight))
      $height=$bottom.Y-$start.Y;$cursorX=[int]($originX+$window.Width/2);$cursorY=[int]($start.Y+$height/2)
      $script:drag=@{x=$cursorX;y=$cursorY;left=$rect.Left;top=$rect.Top;moved=$true};$event=[pscustomobject]@{Handled=$false}
      $points=@();for($n=0;$n-le 16;$n++){$points+=($cursorY-$n*60*$zoom*$dpi)}
      for($n=0;$n-le 32;$n++){$points+=($cursorY-960*$zoom*$dpi+$n*60*$zoom*$dpi)}
      foreach($target in $points){
       [GptWidgetNative]::X=$cursorX;[GptWidgetNative]::Y=[int]$target
       & $pressMove $null $event
       $after=$script:ui.Girl.PointToScreen([Windows.Point]::new(0,0))
       $expected=[Math]::Max($script:frame.Top,[Math]::Min($script:frame.Bottom-$height,$start.Y+[GptWidgetNative]::Y-$cursorY))
       $positionError=[Math]::Abs($after.Y-$expected);$maxError=[Math]::Max($maxError,$positionError)
       if($positionError-gt 1.6){throw ('Vertical drag stopped early: follow='+$follow+' dpi='+$dpi+' character='+$character+' bubble='+$bubble+' side='+$side+' errorPixels='+$positionError+' target='+$target+' start='+$start.Y+' actual='+$after.Y+' expected='+$expected+' height='+$height+' nativeTop='+$script:drag.top+' displayScale='+$script:displayScale+' win='+$window.Width+' nativeHeight='+($rect.Bottom-$rect.Top)+' canvasTop='+[Windows.Controls.Canvas]::GetTop($script:ui.Girl))}
       if($script:side-ne $side){throw 'Vertical drag changed facing'}
       # Run the actual post-release placement calculation at every position.
       $savedTop=New-Object GptWidgetNative+Rect;[GptWidgetNative]::GetWindowRect($script:widgetHandle,[ref]$savedTop)|Out-Null
       $frame=$script:frame;$w=[int](378*$script:displayScale*$dpi);$h=$w
       . $place
       if([Math]::Abs($y-$savedTop.Top)-gt 1){throw 'Post-release placement pushed the character back down'}
       $samples++;$releaseChecks++
      }
      $restTop=Limit-WidgetVerticalPosition $script:frame $dpi -1000000
      $restBottom=Limit-WidgetVerticalPosition $script:frame $dpi 1000000
      foreach($pressScale in @(.82,1.12)){
       $script:ui.PressScale.ScaleY=$pressScale
       if((Limit-WidgetVerticalPosition $script:frame $dpi -1000000)-ne $restTop -or (Limit-WidgetVerticalPosition $script:frame $dpi 1000000)-ne $restBottom){throw 'Press or rebound animation changed the drag limits'}
      }
      $script:ui.PressScale.ScaleY=1;$script:drag=$null;$cases++
     }
    }
   }
  }
 }
}finally{if($window){$window.Close()};if($previousDpiContext-ne [IntPtr]::Zero){[GptWidgetNative]::SetThreadDpiAwarenessContext($previousDpiContext)|Out-Null}}
$r=@{passed=$true;cases=$cases;samples=$samples;postReleaseChecks=$releaseChecks;maxErrorPixels=$maxError;hostAndDesktop=$true;bothFacingDirections=$true;userWindowsMoved=$false}
if($ResultFile){[IO.File]::WriteAllText($ResultFile,($r|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
Write-Output ('PASS: '+$cases+' WPF vertical-drag cases, '+$samples+' positions and '+$releaseChecks+' post-release placements')
