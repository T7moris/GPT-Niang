param([string]$OutputDirectory,[string]$ResultFile)
$ErrorActionPreference='Stop'
$script:appDir=Split-Path $PSScriptRoot -Parent
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime/music.ps1'),[Text.Encoding]::UTF8)))
Initialize-WidgetMusicTypes
. (Join-Path $script:appDir 'runtime/host-follow.ps1')
$follower=[GptWidgetHostFollower]::new([IntPtr]::Zero)
try{$nativeDelegate=[Delegate]::CreateDelegate([Action[int,int]],$follower,'SetTemporaryOffset');$nativeDelegate.Invoke(0,0)}finally{$follower.Dispose()}
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class MusicVisualProbe {
 [StructLayout(LayoutKind.Sequential)]public struct Rect{public int Left,Top,Right,Bottom;}
 [StructLayout(LayoutKind.Sequential)]public struct Point{public int X,Y;}
 [DllImport("user32.dll")]public static extern bool GetCursorPos(out Point point);
 [DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")]public static extern uint GetWindowThreadProcessId(IntPtr h,out uint processId);
 [DllImport("user32.dll")]public static extern uint GetDpiForWindow(IntPtr h);
 [DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")]public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")]public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int height,uint flags);
 [DllImport("user32.dll")]public static extern IntPtr GetWindow(IntPtr h,uint command);
 [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")]public static extern IntPtr GetWindowLongPtr(IntPtr h,int i);
 [DllImport("user32.dll",EntryPoint="SetWindowLongPtrW")]public static extern IntPtr SetWindowLongPtr(IntPtr h,int i,IntPtr v);
 public static void NoMove(int x,int y){}
}
'@
$script:musicVisualActivation=[pscustomobject]@{own=$false}
function Pump([int]$Milliseconds){
 $frame=[Windows.Threading.DispatcherFrame]::new();$timer=[Windows.Threading.DispatcherTimer]::new()
 $timer.Interval=[TimeSpan]::FromMilliseconds(16);$deadline=[DateTime]::UtcNow.AddMilliseconds($Milliseconds);$trace=$script:musicVisualActivation
 $handler={param($sender,$event)
  [uint32]$foregroundPid=0;[MusicVisualProbe]::GetWindowThreadProcessId([MusicVisualProbe]::GetForegroundWindow(),[ref]$foregroundPid)|Out-Null
  if($foregroundPid-eq $PID){$trace.own=$true}
  if([DateTime]::UtcNow-ge $deadline){$sender.Stop();$frame.Continue=$false}
 }.GetNewClosure()
 $timer.Add_Tick($handler);$timer.Start();[Windows.Threading.Dispatcher]::PushFrame($frame);$timer.Remove_Tick($handler)
}
function Save-Pose([string]$Name){
 if(!$OutputDirectory){return}
 $stage=$window.FindName('AnimationStage');$stage.UpdateLayout()
 $render=[Windows.Media.Imaging.RenderTargetBitmap]::new(378,378,96,96,[Windows.Media.PixelFormats]::Pbgra32);$render.Render($stage)
 $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($render))
 $stream=[IO.File]::Create((Join-Path $OutputDirectory $Name));try{$encoder.Save($stream)}finally{$stream.Dispose()}
}
if($OutputDirectory){$null=New-Item -ItemType Directory -Path $OutputDirectory -Force}
$foreground=[MusicVisualProbe]::GetForegroundWindow();$music=$null;$window=$null
try{
 $window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $script:appDir 'widget.xaml'),[Text.Encoding]::UTF8))
 $window.Width=$window.Height=378;$window.Left=120;$window.Top=140
 $girl=$window.FindName('Girl');$girl.Source=[Windows.Media.Imaging.BitmapImage]::new([Uri](Join-Path $script:appDir 'assets/gpt-dragon-niang-bust.png'))
 $window.FindName('Bubble').Visibility='Collapsed';$window.FindName('Tail').Visibility='Collapsed';$window.FindName('TailNear').Visibility='Collapsed'
 $native=[Windows.Interop.WindowInteropHelper]::new($window);$handle=$native.EnsureHandle()
 $style=[MusicVisualProbe]::GetWindowLongPtr($handle,-20).ToInt64()
 [MusicVisualProbe]::SetWindowLongPtr($handle,-20,[IntPtr]($style-bor 0x08000080))|Out-Null
 $window.Show();Pump 70
 [MusicVisualProbe]::SetWindowPos($handle,[IntPtr](1),0,0,0,0,0x213)|Out-Null
 $rect=New-Object MusicVisualProbe+Rect;[MusicVisualProbe]::GetWindowRect($handle,[ref]$rect)|Out-Null
 $left=[Windows.Controls.Canvas]::GetLeft($girl);$top=[Windows.Controls.Canvas]::GetTop($girl);$transform=$girl.RenderTransform
 $colors=[Windows.Media.Color[]]@('#D773AD','#9A79DC','#579DCF','#43AE94','#DBA15C','#D773AD'|ForEach-Object{[Windows.Media.ColorConverter]::ConvertFromString($_)})
 $move=[Delegate]::CreateDelegate([Action[int,int]],[MusicVisualProbe].GetMethod('NoMove'))
 $music=[GptMusicVisual]::new($window,$girl,$window.FindName('Bubble'),$move,$colors,$true)
 $area=[Windows.Forms.Screen]::FromHandle($handle).WorkingArea
 $testDpi=[MusicVisualProbe]::GetDpiForWindow($handle)/96.0
 $music.Configure($handle,[IntPtr]::Zero,$false,$true,$false,$false,$rect.Left,$rect.Top,$area.Left,$area.Bottom,$testDpi)
 Pump 180
 $captureDeadline=[DateTime]::UtcNow.AddSeconds(4)
 while(!$music.Audio.Running -and [DateTime]::UtcNow-lt $captureDeadline){Pump 100}
 if(!$music.Audio.Running){
   # Headless CI and RDP sessions may expose no render endpoint. Treat that as
   # an environment skip instead of a product failure; real capture is covered
   # by the dedicated integration run on a machine with audio.
   Write-Output ('SKIP: system playback capture unavailable ('+$music.Audio.Error+')')
   return
 }
 $music.Motion.Phase=2;$music.Motion.Props=1;$music.Motion.Y=$music.Motion.Floor;$music.Redraw();Pump 40
 Save-Pose 'native-music-standing.png'
 $music.Motion.Bend=.40;$girl.RenderTransform.ScaleY=.60;$music.Redraw();Save-Pose 'native-music-press.png'
 $music.Motion.Bend=-.16;$girl.RenderTransform.ScaleY=1.16;$music.Redraw();Save-Pose 'native-music-rebound.png'
 if($music.LampHandle-eq [IntPtr]::Zero){throw 'Top lamp did not create its independent native surface'}
 $lampStyle=[MusicVisualProbe]::GetWindowLongPtr($music.LampHandle,-20).ToInt64()
 if(($lampStyle-band 0x080000A0)-ne 0x080000A0){throw 'Lamp is not click-through and non-activating'}
 if([MusicVisualProbe]::GetWindowLongPtr($music.LampHandle,-8)-ne [IntPtr]::Zero){throw 'Lamp must not acquire an owner that can raise Codex'}
 if([MusicVisualProbe]::GetWindow($handle,2)-ne $music.LampHandle){throw 'Room lighting must sit below the character'}
 $lightRect=New-Object MusicVisualProbe+Rect;[MusicVisualProbe]::GetWindowRect($music.LampHandle,[ref]$lightRect)|Out-Null
 if($lightRect.Right-$lightRect.Left-ne $area.Width -or $lightRect.Bottom-$lightRect.Top-ne $area.Height){throw 'Room lighting does not cover the selected frame'}
 $stableLamp=$music.LampHandle
 for($n=0;$n-lt 3;$n++){
  $music.SetVisibility($true,$true);Pump 50
  if(!$music.Paused -or ![MusicVisualProbe]::IsWindowVisible($stableLamp)){throw 'Interaction pause switched off the dark background'}
  $music.SetVisibility($true,$false);Pump 50
  if($music.LampHandle-ne $stableLamp -or ![MusicVisualProbe]::IsWindowVisible($stableLamp)){throw 'Resuming recreated or hid the dark background'}
 }
 $cursor=New-Object MusicVisualProbe+Point;[MusicVisualProbe]::GetCursorPos([ref]$cursor)|Out-Null
 $music.Motion.X=$music.Motion.Width/2;$music.Motion.Y=$music.Motion.Floor-180*$testDpi
 $music.BeginHold($cursor.X,$cursor.Y);$music.Motion.ThrowX=800*$testDpi;$music.Motion.ThrowY=-150*$testDpi
 $window.FindName('Bubble').Visibility='Visible';$releaseX=$music.Motion.X
 $music.EndHold()
 if($music.Motion.Held -or $music.Motion.Phase-ne 0 -or $music.Paused -or $music.Motion.Vx-lt 770*$testDpi){throw 'MouseUp did not immediately hand the vector to physics while the bubble closes'}
 Pump 80
 if($music.Paused -or $music.Motion.X-lt $releaseX+20*$testDpi -or ![MusicVisualProbe]::IsWindowVisible($stableLamp)){throw 'Closing bubble braked the release or hid the background'}
 $flightSpeed=$music.Motion.Vx;$music.SetVisibility($true,$true);Pump 70
 if([Math]::Abs($music.Motion.Vx-$flightSpeed)-gt .01){throw 'Temporary flight pause consumed the release velocity'}
 $music.SetVisibility($true,$false);$window.FindName('Bubble').Visibility='Collapsed'
 $music.Motion.Phase=2;$music.Motion.Props=1;$music.Motion.Y=$music.Motion.Floor;$music.Motion.Vx=$music.Motion.Vy=0
 if($OutputDirectory){
  $light=[Windows.Interop.HwndSource]::FromHwnd($music.LampHandle).RootVisual
  $render=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$light.Width,[int]$light.Height,96,96,[Windows.Media.PixelFormats]::Pbgra32);$render.Render($light)
  $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($render))
  $stream=[IO.File]::Create((Join-Path $OutputDirectory 'native-nightclub-light.png'));try{$encoder.Save($stream)}finally{$stream.Dispose()}
 }
 $cursor=New-Object MusicVisualProbe+Point;[MusicVisualProbe]::GetCursorPos([ref]$cursor)|Out-Null
 $beforeHoldTime=$music.Motion.Time;$music.BeginHold($cursor.X,$cursor.Y);Pump 300
 if(!$music.Enabled -or !$music.Motion.Held){throw 'Native pickup exited music or failed to hold'}
 if($music.Motion.Time-lt $beforeHoldTime+.18){throw 'Native music simulation stopped requesting frames during pickup'}
 $music.EndHold();Pump 1800
 if(!$music.Enabled -or $music.Motion.Held -or $music.Motion.Phase-ne 2 -or $music.Motion.Impacts-ne 3){throw 'Native release did not land and return to music mode'}
 $music.Stop($false);$after=New-Object MusicVisualProbe+Rect;[MusicVisualProbe]::GetWindowRect($handle,[ref]$after)|Out-Null
 if($after.Left-ne $rect.Left -or $after.Top-ne $rect.Top){throw 'Closing music did not restore the original native position'}
 if([Windows.Controls.Canvas]::GetLeft($girl)-ne $left -or [Windows.Controls.Canvas]::GetTop($girl)-ne $top -or $girl.RenderTransform-ne $transform){throw 'Normal character layout was not restored'}
 if($music.LampHandle-ne [IntPtr]::Zero){throw 'Lamp window leaked after shutdown'}
 $unchanged=[MusicVisualProbe]::GetForegroundWindow()-eq $foreground
 if($script:musicVisualActivation.own){throw 'A music test window or lamp became the foreground application'}
 $result=@{passed=$true;instantReleaseDuringBubbleClose=$true;flightPausePreservesVelocity=$true;darkBackgroundStableAcrossInteraction=$true;layoutRestored=$true;positionRestored=$true;lampClickThrough=$true;lampUnowned=$true;lampDisposed=$true;foregroundUnchanged=$unchanged;externalForegroundChange=(!$unchanged);ownWindowsNeverActivated=$true;nativeCaptureRunning=$true;nativePickupDrop=$true;renderWakeup=$true;roomLightingFrameSized=$true;lightBelowCharacter=$true}
 if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))}
 Write-Output 'PASS: native WPF drawing and frame wakeup, exact layout/position restoration; music windows never activated'
}finally{if($music){$music.Dispose()};if($window){$window.Close()}}
