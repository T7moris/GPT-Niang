param([string]$WidgetSource,[string]$ResultFile)
$ErrorActionPreference='Stop';$app=Split-Path $PSScriptRoot -Parent
if(!$WidgetSource){$WidgetSource=Join-Path $app 'widget.ps1'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
. (Join-Path $app 'runtime\sharp-text.ps1')
$text=[IO.File]::ReadAllText($WidgetSource,[Text.Encoding]::UTF8);$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Widget source did not parse'}
foreach($name in @('Set-Facing','Set-WidgetPixelSize','Get-WidgetLayoutScale','Set-WidgetIndependentLayout','Test-WidgetPlacementFrame','Limit-WidgetVerticalPosition','Limit-WidgetHorizontalPosition','Set-Appearance','Write-WidgetJson','Save-Settings')){
 $f=$ast.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq $name},$true)
 if($f){. ([ScriptBlock]::Create($f.Extent.Text))}
}
foreach($name in @('pressMove','pressUp')){
 $f=$ast.Find({param($n)$n-is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text-eq ('$'+$name)},$true)
 $body=$f.Right.Extent.Text.Trim();Set-Variable -Name $name -Value ([ScriptBlock]::Create($body.Substring(1,$body.Length-2)))
}
$tick=$ast.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq 'Tick-Widget'},$true).Extent.Text
$start=$tick.IndexOf('      $w=[int]($script:designWidth*');$end=$tick.IndexOf('      $position=',$start)
if($start-lt 0 -or $end-lt 0){throw 'Missing production release placement'}
$place=[ScriptBlock]::Create($tick.Substring($start,$end-$start))
$load=$ast.Find({param($n)$n-is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if($settings.layoutVersion-eq 2)')},$true)
if(!$load){throw 'Missing production saved-position loader'}
$loadPosition=[ScriptBlock]::Create($load.Extent.Text)
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class GptWidgetNative {
 public struct Point{public int X,Y;}public struct Rect{public int Left,Top,Right,Bottom;}
 public static int X,Y,Moves;
 public static bool GetCursorPos(out Point p){p=new Point{X=X,Y=Y};return true;}
 [DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")]public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
 [DllImport("user32.dll",EntryPoint="SetWindowPos")]static extern bool Move(IntPtr h,IntPtr a,int x,int y,int w,int ht,uint f);
 public static bool SetWindowPos(IntPtr h,IntPtr a,int x,int y,int w,int ht,uint f){Moves++;return Move(h,a,x,y,w,ht,f);}
}
'@
function Get-WidgetPlacementFrame{return $script:frame}
function Get-WidgetPlacementDpi{return $script:testDpi}
function Sync-WidgetCharacterColors{}
function Test-WidgetMusicActive{return $false}
function Reset-WidgetAutoQuoteSchedule{}
function Animate-Press{}
function Play-WidgetReleaseSound{}
function Click-Character{throw 'A completed drag became a click'}
function Pump-Layout {
 $queue=[Windows.Threading.DispatcherFrame]::new();$timer=[Windows.Threading.DispatcherTimer]::new()
 $timer.Interval=[TimeSpan]::FromMilliseconds(16)
 $handler={param($sender,$event)$sender.Stop();$queue.Continue=$false}.GetNewClosure()
 $timer.Add_Tick($handler);$timer.Start();[Windows.Threading.Dispatcher]::PushFrame($queue);$timer.Remove_Tick($handler)
}
function Bounds {
 $a=$script:ui.Girl.PointToScreen([Windows.Point]::new(0,0))
 $b=$script:ui.Girl.PointToScreen([Windows.Point]::new($script:ui.Girl.ActualWidth,$script:ui.Girl.ActualHeight))
 return [pscustomobject]@{Left=[Math]::Min($a.X,$b.X);Right=[Math]::Max($a.X,$b.X);Center=($a.X+$b.X)/2}
}
function Rect { $r=New-Object GptWidgetNative+Rect;[GptWidgetNative]::GetWindowRect($script:widgetHandle,[ref]$r)|Out-Null;return $r }
$previousDpi=[GptWidgetNative]::SetThreadDpiAwarenessContext([IntPtr](-4))
$temp=Join-Path ([IO.Path]::GetTempPath()) ('niang-horizontal-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $temp
$settingsFile=Join-Path $temp 'settings.json'
$script:designWidth=$script:designHeight=378;$script:hostHandle=[IntPtr](1);$script:widgetMusic=$null
$script:hostEventTimer=New-Object PSObject
$script:hostEventTimer|Add-Member NoteProperty IsEnabled $true
$script:hostEventTimer|Add-Member ScriptMethod Start {}
$sender=New-Object PSObject;$sender|Add-Member ScriptMethod ReleaseMouseCapture {}
$cases=0;$samples=0;$stationary=0;$placements=0;$releases=0;$reloads=0;$negativeReloads=0;$maxError=0.0;$maxStationary=0.0;$window=$null
try{
 $window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $app 'widget.xaml'),[Text.Encoding]::UTF8))
 $window.Left=-9000;$window.Top=-9000;$window.ShowActivated=$false;$script:window=$window;$script:ui=@{}
 foreach($name in @('Root','Girl','Bubble','Tail','TailNear','MenuButton','Refresh','FacingScale','TextFacingScale','PressScale')){$script:ui[$name]=$window.FindName($name)}
 $script:ui.Girl.Source=[Windows.Media.Imaging.BitmapImage]::new([Uri](Join-Path $app 'assets/gpt-dragon-niang-bust.png'))
 $window.Show();$script:widgetHandle=[Windows.Interop.WindowInteropHelper]::new($window).Handle
 foreach($follow in @($true,$false)){
  foreach($dpi in @(1.0,1.25,1.5,2.0)){
   foreach($character in @(.6,1.0,2.5)){
    foreach($bubble in @(.6,1.0,2.5)){
     foreach($widthFactor in @(520,800,2600)){
      $script:followHost=$follow;$script:testDpi=$dpi;$script:scale=$character;$script:bubbleScale=$bubble;$script:side='left'
      $zoom=[Math]::Max($character,$bubble);$width=[int]($widthFactor*$zoom*$dpi)
      $script:frame=[pscustomobject]@{Left=-9000;Top=-9000;Right=(-9000+$width);Bottom=-3000}
      Set-Appearance;Pump-Layout
      $window.Content.Measure([Windows.Size]::new($window.Width,$window.Height))
      $window.Content.Arrange([Windows.Rect]::new(0,0,$window.Width,$window.Height));$window.Content.UpdateLayout()
      [GptWidgetNative]::SetWindowPos($script:widgetHandle,[IntPtr]::Zero,(-9000+[int]($width*.25)),-8000,0,0,0x15)|Out-Null
      $initial=Bounds;$bodyWidth=$initial.Right-$initial.Left;$r=Rect
      $startCursor=[int][Math]::Round($initial.Center+12*$dpi);$cursorY=-7800
      $script:drag=@{x=$startCursor;y=$cursorY;left=$r.Left;top=$r.Top;moved=$true}
      $event=[pscustomobject]@{Handled=$false};$previousPoint=$null;$previousCursor=0
      $positions=@();for($n=0;$n-le 20;$n++){$positions+=(-9000+$width*(.05+.9*$n/20))}
      for($n=0;$n-le 20;$n++){$positions+=(-9000+$width*(.95-.9*$n/20))}
      foreach($target in $positions){
       foreach($repeat in 0,1){
        [GptWidgetNative]::X=[int]$target;[GptWidgetNative]::Y=$cursorY;$calls=[GptWidgetNative]::Moves
        & $pressMove $null $event
        $after=Bounds
        $expected=[Math]::Max($script:frame.Left+$bodyWidth/2,[Math]::Min($script:frame.Right-$bodyWidth/2,$initial.Center+[GptWidgetNative]::X-$startCursor))
        $positionError=[Math]::Abs($after.Center-$expected);$maxError=[Math]::Max($maxError,$positionError)
        if($positionError-gt 1.6){throw ('Horizontal position error: follow='+$follow+' dpi='+$dpi+' character='+$character+' bubble='+$bubble+' width='+$widthFactor+' error='+$positionError)}
        if($after.Left-lt $script:frame.Left-1.6 -or $after.Right-gt $script:frame.Right+1.6){throw 'Resting character escaped its horizontal limits'}
        if([GptWidgetNative]::Moves-ne $calls+1){throw 'Drag must issue one native move per event'}
        if($null-ne $previousPoint -and $previousCursor-eq [GptWidgetNative]::X){
         $delta=[Math]::Abs($after.Center-$previousPoint);$maxStationary=[Math]::Max($maxStationary,$delta)
         if($delta-gt 1.1){throw ('Same pointer moved character by '+$delta+' pixels')};$stationary++
        }
        $previousPoint=$after.Center;$previousCursor=[GptWidgetNative]::X
        $r=Rect;$frame=$script:frame;$w=[int](378*$script:displayScale*$dpi);$h=$w
        . $place
        if([Math]::Abs($x-$r.Left)-gt 1){throw 'Post-release placement would shift the character'}
        $samples++;$placements++
       }
      }
      # Exercise the actual mouse-up, saved-position reader, and placement at both edges and the middle.
      foreach($fraction in @(0.0,.2,.5,.8,1.0)){
       $r=Rect;$script:drag=@{x=[GptWidgetNative]::X;y=$cursorY;left=$r.Left;top=$r.Top;moved=$true}
       [GptWidgetNative]::X=[int]($script:frame.Left+$width*$fraction)
       & $pressMove $null $event
       $r=Rect;$sideBefore=$script:side
       $snap=if($follow -and $script:side-eq 'left' -and $script:offsetLeft-ge 0 -and $script:offsetLeft-le 18){$script:frame.Left}
        elseif($follow -and $script:side-eq 'right' -and $script:offsetRight-ge 0 -and $script:offsetRight-le 18){$script:frame.Right-[int](378*$script:displayScale*$dpi)}else{$r.Left}
       & $pressUp $sender $event
       if($script:side-ne $sideBefore){throw 'Release flipped the character to the opposite edge'}
       $frame=$script:frame;$w=[int](378*$script:displayScale*$dpi);$h=$w;. $place
       if([Math]::Abs($x-$snap)-gt 1){throw ('Release changed horizontal position unexpectedly: '+$x+' expected '+$snap)}
       $releaseX=$x;$settings=[IO.File]::ReadAllText($settingsFile,[Text.Encoding]::UTF8)|ConvertFrom-Json
       if($follow){
        $savedLeft=$script:offsetLeft;$script:offsetLeft=$null;. $loadPosition;. $place
        if([Math]::Abs($x-$releaseX)-gt 1 -or [Math]::Abs($script:offsetLeft-$savedLeft)-gt .0001){throw 'Saved free horizontal offset was clamped on reopen'}
        if($savedLeft-lt 0){$negativeReloads++};$reloads++
       }
       [GptWidgetNative]::SetWindowPos($script:widgetHandle,[IntPtr]::Zero,$x,$y,0,0,0x15)|Out-Null
       $releases++
      }
      # Press and rebound must not change the resting horizontal limits.
      if(Get-Command Limit-WidgetHorizontalPosition -ErrorAction SilentlyContinue){
       $a=Limit-WidgetHorizontalPosition $script:frame $dpi -1000000;$b=Limit-WidgetHorizontalPosition $script:frame $dpi 1000000
       foreach($press in @(.85,1.05,1.12)){
        $script:ui.PressScale.ScaleX=$press
        if((Limit-WidgetHorizontalPosition $script:frame $dpi -1000000)-ne $a -or (Limit-WidgetHorizontalPosition $script:frame $dpi 1000000)-ne $b){throw 'Press changed horizontal drag bounds'}
       }
       $script:ui.PressScale.ScaleX=1
      }
      $script:drag=$null;$cases++
     }
    }
   }
  }
 }
 if(!$negativeReloads){throw 'Negative free offsets were not exercised'}
}finally{
 if($window){Pump-Layout;$window.Close()}
 if($previousDpi-ne [IntPtr]::Zero){[GptWidgetNative]::SetThreadDpiAwarenessContext($previousDpi)|Out-Null}
 $resolved=[IO.Path]::GetFullPath($temp);$expectedParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
 if([IO.Path]::GetDirectoryName($resolved)-ine $expectedParent -or !(Split-Path $resolved -Leaf).StartsWith('niang-horizontal-')){throw 'Unsafe fixture cleanup'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
$result=@{passed=$true;cases=$cases;samples=$samples;stationaryChecks=$stationary;postReleasePlacementChecks=$placements;realReleaseChecks=$releases;savedPositionReloadChecks=$reloads;negativeOffsetReloadChecks=$negativeReloads;maxPositionErrorPixels=$maxError;maxStationaryMotionPixels=$maxStationary;hostAndDesktop=$true;userWindowsMoved=$false}
if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
Write-Output ('PASS: '+$cases+' horizontal cases, '+$samples+' positions, '+$stationary+' stationary checks, '+$releases+' actual releases and '+$reloads+' saved-position reloads')
