param([string]$TestRoot=$PSScriptRoot,[string]$WidgetSource)
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $TestRoot -Parent) 'runtime\low-power-dock.ps1')
if(!$WidgetSource){$WidgetSource=Join-Path (Split-Path $TestRoot -Parent) 'widget.ps1'}
$source=[IO.File]::ReadAllText($WidgetSource,[Text.Encoding]::UTF8)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$move=$ast.Find({param($node)$node-is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text-eq '$pressMove'},$true)
$pressMove=[ScriptBlock]::Create($move.Right.Extent.Text.Trim().Substring(1,$move.Right.Extent.Text.Trim().Length-2))
$tick=$ast.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq 'Tick-Widget'},$true)
. ([ScriptBlock]::Create($tick.Extent.Text))
$dockMove=$ast.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq 'Move-LowPowerDrag'},$true)
. ([ScriptBlock]::Create($dockMove.Extent.Text))
Add-Type -TypeDefinition @'
using System;
public static class GptWidgetNative {
 public struct Point {public int X,Y;}
 public struct Rect {public int Left,Top,Right,Bottom;}
 public static Rect Frame(IntPtr h){return new Rect{Left=0,Top=0,Right=8000,Bottom=6000};}
 public static int X,Y,Width,Height,Calls,PlacedX,PlacedY;public static uint Flags;
 public static bool GetCursorPos(out Point point){point=new Point{X=X,Y=Y};return true;}
 public static bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags){PlacedX=x;PlacedY=y;Width=width;Height=height;Flags=flags;Calls++;return true;}
 public static IntPtr GetForegroundWindow(){return new IntPtr(1);}
 public static IntPtr GetAncestor(IntPtr h,uint flags){return h;}
 public static bool IsWindow(IntPtr h){return true;}
 public static bool IsIconic(IntPtr h){return false;}
}
public static class GptWidgetZOrderNative {public static bool VisibleSurface(IntPtr h){return true;}}
'@
function Get-WidgetPlacementFrame {return [pscustomobject]@{Left=$script:frameLeft;Top=$script:frameTop;Right=($script:frameLeft+$script:frameWidth);Bottom=($script:frameTop+$script:frameHeight)}}
function Get-WidgetPlacementDpi {return $script:testDpi}
function Set-Facing {}
function Set-LowPowerLayout {}
# Actual physical sizing is exercised against real HWNDs by display/size tests.
function Set-WidgetPixelSize {}
$validFrame=$ast.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq 'Test-WidgetPlacementFrame'},$true)
. ([ScriptBlock]::Create($validFrame.Extent.Text))
$script:designWidth=378;$script:designHeight=378
function Tick-Scene {}
function Tick-WidgetUpdater {}
function Ensure-QuotaWorker {}
function Test-WidgetHostReady {return $true}
function Set-WidgetAboveHost {}
function Set-WidgetDesktopLayer {}
function Request-Refresh {}
function Assert-SizeAfterNativeMove([string]$Context){
  # Reproduce the failure when the host DPI differs from the WPF window DPI:
  # WM_SIZE feeds a native resize back into Window.Width/Height in its own DIPs.
  if(([GptWidgetNative]::Flags-band 1)-eq 0){
    $script:window.Width=[GptWidgetNative]::Width
    $script:window.Height=[GptWidgetNative]::Height
  }
  if($script:window.Width-ne 378 -or $script:window.Height-ne 378){throw ('Window size changed during '+$Context+' at DPI '+$script:testDpi)}
  if($script:scale-ne 1){throw 'Placement changed the user scale.'}
}
$script:hostHandle=[IntPtr](1);$script:widgetHandle=[IntPtr](2)
$script:hostReadiness=[pscustomobject]@{desktopStarted=$true}
$script:context=[pscustomobject]@{IsOpen=$false}
$script:hostFollower=New-Object PSObject
$script:hostFollower|Add-Member ScriptMethod Configure {}
$script:hostFollower|Add-Member ScriptMethod Suspend {}
$script:lastForeground=[IntPtr](1);$script:attachedHost=[IntPtr](1)
$script:lastPresence=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()+3600000
$script:dataDir=$TestRoot
$cases=0
$script:frameWidth=8000;$script:frameHeight=6000
$script:frameLeft=0;$script:frameTop=0
foreach($follow in @($true,$false)){
  foreach($dpi in @(1.0,1.5,2.0)){
    $script:testDpi=$dpi;$script:followHost=$follow
    $script:window=[pscustomobject]@{Width=378;Height=378;IsVisible=$true}
    $script:scale=1.0;$script:displayScale=1.0
    $script:offsetLeft=20;$script:offsetRight=0;$script:offsetBottom=0;$script:anchor='free'
    $script:desktopLeft=100;$script:desktopTop=100
    $script:drag=@{x=0;y=0;left=100;top=100;moved=$false}
    $event=[pscustomobject]@{Handled=$false}
    for($i=0;$i-lt 20;$i++){
      [GptWidgetNative]::X=100+$i*10;[GptWidgetNative]::Y=100+$i*7
      $before=[GptWidgetNative]::Calls
      & $pressMove $null $event
      if([GptWidgetNative]::Calls-ne $before+1){throw 'Drag did not move the native window.'}
      Assert-SizeAfterNativeMove 'dragging'
    }
    $script:drag=$null
    for($i=0;$i-lt 20;$i++){
      $script:lastPosition=$null;$before=[GptWidgetNative]::Calls
      Tick-Widget
      if([GptWidgetNative]::Calls-ne $before+1){throw 'Placement tick did not move the native window.'}
      Assert-SizeAfterNativeMove 'placement ticks'
    }
    $cases++
  }
}
Write-Output ('PASS: '+$cases+' host/desktop DPI cases preserve 100% size through 20 drags and 20 placement ticks each')
$script:hostFollower|Add-Member NoteProperty LastConfiguration $null
$script:hostFollower|Add-Member ScriptMethod Configure {$this.LastConfiguration=$args} -Force
foreach($follow in @($true,$false)){
  foreach($dpi in @(1.0,1.25,1.5,2.0)){
    foreach($side in @('left','right')){
      $script:followHost=$follow;$script:testDpi=$dpi;$script:side=$side;$script:lowPower=$true
      $script:lowPowerHostDock=$null;$script:lowPowerDesktopDock=$null
      $script:offsetLeft=73;$script:offsetRight=91;$script:offsetBottom=45;$script:anchor='free'
      $script:desktopLeft=100;$script:desktopTop=200;$script:lastPosition=$null
      Tick-Widget
      $width=[int](378*$dpi);$height=[int](378*$dpi)
      $expectedX=if($side-eq 'left'){0}else{$script:frameWidth-$width}
      $expectedY=[int](($script:frameHeight-208*$dpi)/2-170*$dpi)
      if([GptWidgetNative]::PlacedX-ne $expectedX -or [GptWidgetNative]::PlacedY-ne $expectedY){throw 'Default low-power pose is not centered on the left/right edge'}
      $dock=Get-LowPowerDock
      if($dock.edge-ne $side -or $dock.dragged){throw 'Fresh low-power mode did not default to its horizontal side'}
      if($follow){
        $configuration=$script:hostFollower.LastConfiguration
        if($configuration[7]-ne $expectedX -or $configuration[9]-ne ($script:frameHeight-$height-$expectedY) -or $configuration[10]-ne 'free'){throw 'Native host follower did not retain edge docking'}
      }
      if($script:offsetLeft-ne 73 -or $script:offsetRight-ne 91 -or $script:offsetBottom-ne 45 -or $script:desktopLeft-ne 100 -or $script:desktopTop-ne 200){throw 'Low-power docking overwrote normal placement'}
      $script:lowPower=$false;$script:lastPosition=$null;Tick-Widget
      $normalX=if($follow){[int](73*$dpi)}else{100}
      $normalY=if($follow){[int]($script:frameHeight-$height-45*$dpi)}else{200}
      if([GptWidgetNative]::PlacedX-ne $normalX -or [GptWidgetNative]::PlacedY-ne $normalY){throw 'Normal position was not restored after docking'}
    }
  }
}
Write-Output 'PASS: low-power host/desktop edge docking, native follow configuration and position restoration at four DPIs on both sides'
$script:lowPower=$true
foreach($follow in @($true,$false)){
  $script:followHost=$follow
  foreach($dpi in @(1,1.25,1.5,2)){
    $script:testDpi=$dpi
    foreach($origin in @(@(0,0),@(-2560,-300))){
      $script:frameLeft=$origin[0];$script:frameTop=$origin[1]
      $frame=Get-WidgetPlacementFrame
      foreach($destination in @(@('left',$frame.Left,($frame.Top+1500)),@('right',$frame.Right,($frame.Top+2500)),@('top',($frame.Left+2500),$frame.Top),@('bottom',($frame.Left+4500),$frame.Bottom))){
        $script:drag=@{x=0;y=0;moved=$false};$script:lastPosition=$null
        [GptWidgetNative]::X=$destination[1];[GptWidgetNative]::Y=$destination[2]
        & $pressMove $null ([pscustomobject]@{Handled=$false})
        $dock=Get-LowPowerDock;$geometry=Get-LowPowerGeometry $frame $dpi
        if($dock.edge-ne $destination[0] -or !$dock.dragged){throw 'Drag did not select and remember the closest boundary'}
        $size=208*$script:displayScale*$dpi
        $expectedAlong=if($dock.edge-in @('top','bottom')){($destination[1]-$frame.Left-$size/2)/($script:frameWidth-$size)}else{($destination[2]-$frame.Top-$size/2)/($script:frameHeight-$size)}
        if([Math]::Abs($dock.along-$expectedAlong)-gt 0.000001){throw 'Dragging rounded a fractional edge position to a corner'}
        $gap=switch($dock.edge){'left'{$geometry.ImageLeft-$frame.Left};'right'{$frame.Right-$geometry.ImageLeft-$size};'top'{$geometry.ImageTop-$frame.Top};'bottom'{$frame.Bottom-$geometry.ImageTop-$size}}
        if([Math]::Abs($gap)-gt 0.01){throw 'Dragged picture is not flush to the selected boundary'}
        if([GptWidgetNative]::PlacedX-ne $geometry.X -or [GptWidgetNative]::PlacedY-ne $geometry.Y){throw 'Dragging did not move the native window to the dock geometry'}
        if(!$follow -and ($dock.monitorX-ne $destination[1] -or $dock.monitorY-ne $destination[2])){throw 'Desktop drag did not remember the selected monitor'}
        $script:drag=$null;Tick-Widget
        if([GptWidgetNative]::PlacedX-ne $geometry.X -or [GptWidgetNative]::PlacedY-ne $geometry.Y){throw 'Release/timer update lost the dragged dock position'}
        if($script:offsetLeft-ne 73 -or $script:offsetRight-ne 91 -or $script:offsetBottom-ne 45 -or $script:desktopLeft-ne 100 -or $script:desktopTop-ne 200){throw 'Edge dragging overwrote normal placement'}
      }
    }
  }
}
$script:lowPower=$false;$script:frameLeft=0;$script:frameTop=0
Write-Output 'PASS: actual drag handler follows all four host/desktop edges at four DPIs, including negative monitor coordinates, without moving normal placement'
$script:followHost=$true;$script:testDpi=1.25
$script:window|Add-Member ScriptMethod Hide {$this.IsVisible=$false}
$script:window|Add-Member ScriptMethod Show {$this.IsVisible=$true}
$script:frameWidth=2;$script:frameHeight=2
$script:lastPosition=$null
Tick-Widget
if($script:window.IsVisible){throw 'Transient 2x2 host frame was treated as usable'}
Assert-SizeAfterNativeMove 'transient 2x2 host'
if($script:displayScale-ne 1){throw 'Transient host frame changed saved display scale'}
$script:frameWidth=8000;$script:frameHeight=6000
Tick-Widget
if(!$script:window.IsVisible){throw 'Widget did not recover after valid host frame returned'}
Assert-SizeAfterNativeMove 'host restart recovery'
Write-Output 'PASS: temporary 2x2 host hides without resizing; valid host restores the existing size'
