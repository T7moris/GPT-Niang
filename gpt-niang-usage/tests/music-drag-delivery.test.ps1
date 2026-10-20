param([string]$AppDirectory=(Split-Path $PSScriptRoot -Parent),[string]$ResultFile)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml,System.Windows.Forms,System.Drawing
$visual=[IO.File]::ReadAllText((Join-Path $AppDirectory 'runtime/music-visual.cs'))
$visual=$visual.Replace('girl.IsMouseCaptured','MusicDragInputProbe.Captured').Replace('MusicNative.GetCursorPos(out cursor)','MusicDragInputProbe.GetCursor(out cursor)')
$visual=[regex]::Replace($visual,'(?m)^using [^;\r\n]+;\r?\n','')
$audio=[regex]::Replace([IO.File]::ReadAllText((Join-Path $AppDirectory 'runtime/music-audio.cs')),'(?m)^using [^;\r\n]+;\r?\n','')
$using='using System;using System.Diagnostics;using System.Runtime.InteropServices;using System.Threading;using System.Windows;using System.Windows.Controls;using System.Windows.Interop;using System.Windows.Input;using System.Windows.Media;using System.Windows.Media.Imaging;using System.Windows.Threading;'
$helper=@'
public static class MusicDragInputProbe {
 public static bool Captured;public static int X,Y;
 internal static bool GetCursor(out MusicNative.Point p){p=new MusicNative.Point{X=X,Y=Y};return true;}
 [StructLayout(LayoutKind.Sequential)]public struct Rect{public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")]public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
 public static bool Move(Image girl,int x,int y){X=x;Y=y;var e=new MouseEventArgs(Mouse.PrimaryDevice,Environment.TickCount){RoutedEvent=Mouse.PreviewMouseMoveEvent};girl.RaiseEvent(e);return e.Handled;}
 public static void Wait(int ms){Thread.Sleep(ms);}
}
'@
$references=@('System.dll','System.Core.dll','System.Xaml.dll','System.Windows.Forms.dll','System.Drawing.dll',[Windows.Window].Assembly.Location,[Windows.Media.Brush].Assembly.Location,[Windows.Point].Assembly.Location)
Add-Type -TypeDefinition ($using+[Environment]::NewLine+$audio+[Environment]::NewLine+$visual+[Environment]::NewLine+$helper) -ReferencedAssemblies $references
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $AppDirectory 'runtime/host-follow.ps1'))))
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $AppDirectory 'runtime/host-layer.ps1'))))
$hostWindow=$null;$window=$null;$follower=$null;$music=$null;$fail=[Collections.Generic.List[string]]::new();$foreground=[MusicDragInputProbe]::GetForegroundWindow()
function Bounds([IntPtr]$Handle){$r=New-Object MusicDragInputProbe+Rect;[MusicDragInputProbe]::GetWindowRect($Handle,[ref]$r)|Out-Null;return $r}
function Check([bool]$Passed,[string]$Message){if(!$Passed){$script:fail.Add($Message)}}
try{
 $hostWindow=[Windows.Window]::new();$hostWindow.Width=1200;$hostWindow.Height=850;$hostWindow.Left=-5000;$hostWindow.Top=-5000;$hostWindow.ShowActivated=$false;$hostWindow.ShowInTaskbar=$false;$hostWindow.WindowStyle='None';$hostWindow.Show()
 $hostHandle=[Windows.Interop.WindowInteropHelper]::new($hostWindow).Handle
 $window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $AppDirectory 'widget.xaml')));$window.Width=$window.Height=378;$window.Left=-4700;$window.Top=-4900
 $girl=$window.FindName('Girl');$girl.Source=[Windows.Media.Imaging.BitmapImage]::new([Uri](Join-Path $AppDirectory 'assets/gpt-dragon-niang-bust.png'))
 foreach($part in @('Bubble','Tail','TailNear')){$window.FindName($part).Visibility='Collapsed'}
 $window.Show();$handle=[Windows.Interop.WindowInteropHelper]::new($window).Handle;Set-WidgetAboveHost $handle $hostHandle|Out-Null
 $hr=Bounds $hostHandle;$wr=Bounds $handle
 $follower=[GptWidgetHostFollower]::new($handle);$follower.Configure($hostHandle,$hr.Left,$hr.Top,$hr.Right,$hr.Bottom,($wr.Right-$wr.Left),($wr.Bottom-$wr.Top),300,0,0,'free',$true)
 $move=[Delegate]::CreateDelegate([Action[int,int]],$follower,'SetTemporaryOffset')
 $palette=[Windows.Media.Color[]]@('#D773AD','#9A79DC','#579DCF','#43AE94','#DBA15C','#D773AD'|ForEach-Object{[Windows.Media.ColorConverter]::ConvertFromString($_)})
 $music=[GptMusicVisual]::new($window,$girl,$window.FindName('Bubble'),$move,$palette,$true);$music.FollowLamp=[Delegate]::CreateDelegate([Action[IntPtr,int,int,int]],$follower,'SetCompanion');$music.HostFrame=[Delegate]::CreateDelegate([Func[int[]]],$follower,'GetFrame')
 $music.Configure($handle,$hostHandle,$true,$true,$false,$false,$wr.Left,$wr.Top,$hr.Left,$hr.Bottom,1)
 $music.Motion.Phase=2;$music.Motion.Props=1;$music.Motion.Y=$music.Motion.Floor
 $lamp=$music.LampHandle;$start=Bounds $handle;$cursorX=[int]($hr.Left+$music.Motion.X);$cursorY=[int]($hr.Top+$music.Motion.Y-60)
 [MusicDragInputProbe]::X=$cursorX;[MusicDragInputProbe]::Y=$cursorY
 Check (![MusicDragInputProbe]::Move($girl,($cursorX+12),$cursorY)) 'Unheld mouse movement was consumed'
 $music.BeginHold($cursorX,$cursorY);[MusicDragInputProbe]::Captured=$true
 $handled=0;$immediate=0;$durations=[Collections.Generic.List[double]]::new()
 for($i=1;$i-le 24;$i++){
  [MusicDragInputProbe]::Wait(4);$clock=[Diagnostics.Stopwatch]::StartNew();$consumed=[MusicDragInputProbe]::Move($girl,($cursorX+$i*10),($cursorY-40));$clock.Stop();$durations.Add($clock.Elapsed.TotalMilliseconds)
  if($consumed){$handled++};$current=Bounds $handle;if([Math]::Abs($current.Left-($start.Left+$i*10))-le 1){$immediate++}
 }
 Check ($immediate-eq 24) 'Held movement waits for rendering or queued delivery'
 Check ($handled-eq 24) 'Held pointer events continue into the PowerShell mouse-move path'
 Check ($music.LampHandle-eq $lamp-and [MusicDragInputProbe]::IsWindowVisible($lamp)) 'Held movement replaced or hid the accepted background'
 Check ($music.Motion.ThrowX-gt 0) 'Direct drag stopped sampling release velocity'
 [MusicDragInputProbe]::Captured=$false;$before=Bounds $handle;Check (![MusicDragInputProbe]::Move($girl,($cursorX+270),$cursorY)) 'Uncaptured move was consumed';$after=Bounds $handle;Check ($before.Left-eq $after.Left) 'Uncaptured move changed position'
 [MusicDragInputProbe]::Captured=$true;$music.SetVisibility($true,$true);$before=Bounds $handle;[void][MusicDragInputProbe]::Move($girl,($cursorX+280),$cursorY);$after=Bounds $handle;Check ($before.Left-eq $after.Left) 'Blocked interaction moved the character'
 $music.SetVisibility($true,$false);$music.EndHold();$releaseOkay=(!$music.Motion.Held-and $music.Motion.Phase-eq 0-and $music.Motion.Vx-gt 0);Check $releaseOkay 'Release did not resume original flight physics'
 $music.Motion.BeginHold();$music.Stop($false);Check (![MusicDragInputProbe]::Move($girl,($cursorX+290),$cursorY)) 'Stopped controller retained its mouse handler'
 Check (![MusicDragInputProbe]::IsWindowVisible($lamp)) 'Stopping music left the background visible'
 Check (!$music.Error) 'Visual controller reported an error'
 $result=@{passed=($fail.Count-eq 0);failures=$fail.ToArray();pointerEvents=24;immediateNativeMoves=$immediate;handledEvents=$handled;noRenderOrDispatcherPumpBetweenInputs=$true;syntheticCaptureAndCursor=$true;physicalMouseUsed=$false;testWindowsOffscreen=$true;foregroundUnchanged=([MusicDragInputProbe]::GetForegroundWindow()-eq $foreground);deliveryMs=@{mean=($durations|Measure-Object -Average).Average;max=($durations|Measure-Object -Maximum).Maximum};releasePhysicsPreserved=$releaseOkay}
 if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))};$result|ConvertTo-Json -Depth 7
 if($fail.Count){throw ($fail-join '; ')}
}finally{[MusicDragInputProbe]::Captured=$false;if($music){$music.Dispose()};if($follower){$follower.Dispose()};if($window){$window.Close()};if($hostWindow){$hostWindow.Close()}}
