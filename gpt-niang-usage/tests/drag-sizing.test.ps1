param([string]$TestRoot=$PSScriptRoot,[string]$WidgetSource)
$ErrorActionPreference='Stop'
if(!$WidgetSource){$WidgetSource=Join-Path (Split-Path $TestRoot -Parent) 'widget.ps1'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
. (Join-Path (Split-Path $WidgetSource -Parent) 'runtime\sharp-text.ps1')
. (Join-Path (Split-Path $WidgetSource -Parent) 'runtime\quotes.ps1')
Initialize-WidgetAutoQuoteSettings $null
. (Join-Path (Split-Path $WidgetSource -Parent) 'runtime\audio.ps1')
. (Join-Path (Split-Path $WidgetSource -Parent) 'runtime\completion-notifications.ps1')
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path (Split-Path $WidgetSource -Parent) 'runtime/music.ps1'),[Text.Encoding]::UTF8)))
Initialize-CompletionNotificationState $null
$source=[IO.File]::ReadAllText($WidgetSource,[Text.Encoding]::UTF8)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$move=$ast.Find({param($node)$node-is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text-eq '$pressMove'},$true)
$pressMove=[ScriptBlock]::Create($move.Right.Extent.Text.Trim().Substring(1,$move.Right.Extent.Text.Trim().Length-2))
$tick=$ast.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq 'Tick-Widget'},$true)
. ([ScriptBlock]::Create($tick.Extent.Text))
$presence=$ast.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq 'Write-WidgetPresence'},$true)
. ([ScriptBlock]::Create($presence.Extent.Text))
$layoutScale=$ast.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq 'Get-WidgetLayoutScale'},$true)
. ([ScriptBlock]::Create($layoutScale.Extent.Text))
# Actual character limits are covered by drag-vertical and drag-horizontal.
function Limit-WidgetHorizontalPosition {param($Frame,$Dpi,$Left)return [int]$Left}
function Limit-WidgetVerticalPosition {param($Frame,$Dpi,$Top)return [int]$Top}
$autoTick=$ast.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq 'Tick-WidgetAutoQuote'},$true)
. ([ScriptBlock]::Create($autoTick.Extent.Text))
Add-Type -TypeDefinition @'
using System;
public static class GptWidgetNative {
 public struct Point {public int X,Y;}
 public struct Rect {public int Left,Top,Right,Bottom;}
 public static Rect Frame(IntPtr h){return new Rect{Left=0,Top=0,Right=8000,Bottom=6000};}
 public static int X,Y,Width,Height,Calls;public static uint Flags;
 public static bool GetCursorPos(out Point point){point=new Point{X=X,Y=Y};return true;}
 public static bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags){Width=width;Height=height;Flags=flags;Calls++;return true;}
 public static IntPtr GetForegroundWindow(){return new IntPtr(1);}
 public static IntPtr GetAncestor(IntPtr h,uint flags){return h;}
 public static bool IsWindow(IntPtr h){return true;}
 public static bool IsIconic(IntPtr h){return false;}
}
public static class GptWidgetZOrderNative {public static bool VisibleSurface(IntPtr h){return true;}}
'@
function Get-WidgetPlacementFrame {return [pscustomobject]@{Left=0;Top=0;Right=$script:frameWidth;Bottom=$script:frameHeight}}
function Get-WidgetPlacementDpi {return $script:testDpi}
function Set-Facing {}
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
