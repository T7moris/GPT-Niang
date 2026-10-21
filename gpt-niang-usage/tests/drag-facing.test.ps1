param([string]$WidgetSource,[string]$ResultFile)
$ErrorActionPreference='Stop';$app=Split-Path $PSScriptRoot -Parent
if(!$WidgetSource){$WidgetSource=Join-Path $app 'widget.ps1'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
. (Join-Path $app 'runtime\sharp-text.ps1')
$text=[IO.File]::ReadAllText($WidgetSource,[Text.Encoding]::UTF8);$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
foreach($name in @('Set-Facing','Set-WidgetPixelSize','Get-WidgetLayoutScale','Set-WidgetIndependentLayout','Test-WidgetPlacementFrame','Limit-WidgetVerticalPosition','Limit-WidgetHorizontalPosition','Set-Appearance')){
 $f=$ast.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq $name},$true);. ([ScriptBlock]::Create($f.Extent.Text))
}
$f=$ast.Find({param($n)$n-is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text-eq '$pressMove'},$true)
$body=$f.Right.Extent.Text.Trim();$pressMove=[ScriptBlock]::Create($body.Substring(1,$body.Length-2))
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class GptWidgetNative {
 public struct Point{public int X,Y;}public struct Rect{public int Left,Top,Right,Bottom;}
 public static int X,Y,Moves;
 public static bool GetCursorPos(out Point p){p=new Point{X=X,Y=Y};return true;}
 [DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll",EntryPoint="SetWindowPos")]static extern bool Move(IntPtr h,IntPtr a,int x,int y,int w,int ht,uint f);
 public static bool SetWindowPos(IntPtr h,IntPtr a,int x,int y,int w,int ht,uint f){Moves++;return Move(h,a,x,y,w,ht,f);}
}
'@
function Get-WidgetPlacementFrame {return $script:frame}
function Get-WidgetPlacementDpi {return $script:testDpi}
function Sync-WidgetCharacterColors {}
function Test-WidgetMusicActive {return $false}
$script:followHost=$true;$script:hostHandle=[IntPtr](1);$script:designWidth=$script:designHeight=378
$script:hostEventTimer=$null;$script:widgetMusic=$null;$window=$null;$cases=0;$samples=0;$maxError=0.0;$flips=0
try{
 $window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $app 'widget.xaml'),[Text.Encoding]::UTF8))
 $window.Left=-9000;$window.Top=-9000;$window.ShowActivated=$false;$script:window=$window;$script:ui=@{}
 foreach($name in @('Root','Girl','Bubble','Tail','TailNear','MenuButton','Refresh','FacingScale','TextFacingScale')){$script:ui[$name]=$window.FindName($name)}
 $window.Show();$script:widgetHandle=[Windows.Interop.WindowInteropHelper]::new($window).Handle
 foreach($dpi in @(1.0,1.5,2.0)){
  foreach($character in @(.6,1.0,2.5)){
   foreach($bubble in @(.6,1.0,2.5)){
    $script:testDpi=$dpi;$script:scale=$character;$script:bubbleScale=$bubble;$script:side='left';Set-Appearance;$window.UpdateLayout()
    $width=[int](2600*[Math]::Max($character,$bubble)*$dpi)
    $script:frame=[pscustomobject]@{Left=-9000;Top=-9000;Right=(-9000+$width);Bottom=-3000}
    [GptWidgetNative]::SetWindowPos($script:widgetHandle,[IntPtr]::Zero,(-9000+[int]($width*.25)),-8000,0,0,0x15)|Out-Null
    $center=[Windows.Point]::new($script:ui.Girl.ActualWidth/2,$script:ui.Girl.ActualHeight/2)
    $start=$script:ui.Girl.PointToScreen($center);$rect=New-Object GptWidgetNative+Rect;[GptWidgetNative]::GetWindowRect($script:widgetHandle,[ref]$rect)|Out-Null
    $startCursor=[int][Math]::Round($start.X+12*$dpi)
    $script:drag=@{x=$startCursor;y=[int]$start.Y;left=$rect.Left;top=$rect.Top;moved=$true}
    $event=[pscustomobject]@{Handled=$false};$oldSide=$script:side
    # Cross the midpoint in both directions, then make tiny reversals there.
    $positions=@();for($n=0;$n-le 40;$n++){$positions+=($script:frame.Left+$width*(.30+.40*$n/40))}
    for($n=0;$n-le 40;$n++){$positions+=($script:frame.Left+$width*(.70-.40*$n/40))}
    foreach($x in $positions){
     [GptWidgetNative]::X=[int]$x;[GptWidgetNative]::Y=[int]$start.Y;$calls=[GptWidgetNative]::Moves
     & $pressMove $null $event
     $after=$script:ui.Girl.PointToScreen($center);$expected=$start.X+[GptWidgetNative]::X-$startCursor
     $positionError=[Math]::Abs($after.X-$expected);$maxError=[Math]::Max($maxError,$positionError)
     if($positionError-gt 1.1){throw ('Character jumped during facing change: dpi='+$dpi+' character='+$character+' bubble='+$bubble+' error='+$positionError)}
     if([GptWidgetNative]::Moves-ne $calls+1){throw ('Unexpected native move count '+([GptWidgetNative]::Moves-$calls)+' at dpi='+$dpi+' character='+$character+' bubble='+$bubble+' cursor='+$x+' dragstart='+$startCursor)}
     if($script:side-ne $oldSide){$flips++;$oldSide=$script:side};$samples++
    }
    $script:drag=$null;$cases++
   }
  }
 }
}finally{if($window){$window.Close()}}
$r=@{passed=$true;cases=$cases;samples=$samples;flips=$flips;maxPositionErrorPixels=$maxError;oneNativeMovePerEvent=$true;dragOffsetPreserved=$true}
if($ResultFile){[IO.File]::WriteAllText($ResultFile,($r|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
Write-Output ('PASS: '+$cases+' actual WPF size/DPI cases, '+$samples+' drag samples, '+$flips+' flips without a character position jump')
