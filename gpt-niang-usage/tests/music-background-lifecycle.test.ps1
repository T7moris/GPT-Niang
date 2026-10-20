param([string]$AppDirectory=(Split-Path $PSScriptRoot -Parent),[string]$ResultFile)
$ErrorActionPreference='Stop';$script:appDir=$AppDirectory
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $AppDirectory 'runtime/music.ps1'))));Initialize-WidgetMusicTypes
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $AppDirectory 'runtime/host-follow.ps1'))))
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $AppDirectory 'runtime/host-layer.ps1'))))
Add-Type -ReferencedAssemblies @('System.dll',[Windows.Window].Assembly.Location,[Windows.Media.Brush].Assembly.Location,[Windows.Point].Assembly.Location) -TypeDefinition @'
using System;using System.Diagnostics;using System.Runtime.InteropServices;using System.Windows.Interop;using System.Windows.Threading;
public static class BackgroundLifeProbe {
 [StructLayout(LayoutKind.Sequential)]public struct Rect{public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")]public static extern bool SetWindowPos(IntPtr h,IntPtr a,int x,int y,int w,int height,uint f);
 [DllImport("user32.dll")]public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")]public static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")]public static extern IntPtr GetLong(IntPtr h,int i);
 public static void Pump(int ms){var f=new DispatcherFrame();var timer=new DispatcherTimer();var sw=Stopwatch.StartNew();EventHandler tick=delegate{if(sw.ElapsedMilliseconds>=ms){timer.Stop();f.Continue=false;}};timer.Interval=TimeSpan.FromMilliseconds(8);timer.Tick+=tick;timer.Start();try{Dispatcher.PushFrame(f);}finally{timer.Stop();timer.Tick-=tick;}}
}
'@
$hostWindow=$null;$window=$null;$cover=$null;$music=$null;$follower=$null;$fail=@();$foreground=[BackgroundLifeProbe]::GetForegroundWindow()
function Check([bool]$Value,[string]$Message){if(!$Value){$script:fail+=$Message}}
try{
 $hostWindow=[Windows.Window]::new();$hostWindow.Width=1000;$hostWindow.Height=780;$hostWindow.Left=-5000;$hostWindow.Top=-5000;$hostWindow.ShowActivated=$false;$hostWindow.ShowInTaskbar=$false;$hostWindow.WindowStyle='None';$hostWindow.Show()
 $hh=[Windows.Interop.WindowInteropHelper]::new($hostWindow).Handle
 [BackgroundLifeProbe]::SetWindowPos($hh,[IntPtr](1),0,0,0,0,0x213)|Out-Null
 $window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $AppDirectory 'widget.xaml')));$window.Left=-4900;$window.Top=-4900;$window.Width=$window.Height=378
 $girl=$window.FindName('Girl');$girl.Source=[Windows.Media.Imaging.BitmapImage]::new([Uri](Join-Path $AppDirectory 'assets/gpt-dragon-niang-bust.png'))
 foreach($part in @('Bubble','Tail','TailNear')){$window.FindName($part).Visibility='Collapsed'}
 $window.Show();$wh=[Windows.Interop.WindowInteropHelper]::new($window).Handle;Set-WidgetAboveHost $wh $hh|Out-Null
 $hr=New-Object BackgroundLifeProbe+Rect;[BackgroundLifeProbe]::GetWindowRect($hh,[ref]$hr)|Out-Null
 $wr=New-Object BackgroundLifeProbe+Rect;[BackgroundLifeProbe]::GetWindowRect($wh,[ref]$wr)|Out-Null
 $follower=[GptWidgetHostFollower]::new($wh);$follower.Configure($hh,$hr.Left,$hr.Top,$hr.Right,$hr.Bottom,($wr.Right-$wr.Left),($wr.Bottom-$wr.Top),100,0,0,'free',$true)
 $colors=[Windows.Media.Color[]]@('#D773AD','#9A79DC','#579DCF','#43AE94','#DBA15C','#D773AD'|ForEach-Object{[Windows.Media.ColorConverter]::ConvertFromString($_)})
 $music=[GptMusicVisual]::new($window,$girl,$window.FindName('Bubble'),[Delegate]::CreateDelegate([Action[int,int]],$follower,'SetTemporaryOffset'),$colors,$true)
 $music.FollowLamp=[Delegate]::CreateDelegate([Action[IntPtr,int,int,int]],$follower,'SetCompanion');$music.HostFrame=[Delegate]::CreateDelegate([Func[int[]]],$follower,'GetFrame')
 $music.Configure($wh,$hh,$true,$true,$false,$false,$wr.Left,$wr.Top,$hr.Left,$hr.Bottom,1.25)
 Check ($music.LampHandle-ne [IntPtr]::Zero) 'Background waits for the character to land'
 $music.Motion.Phase=2;$music.Motion.Props=1;$music.Motion.Y=$music.Motion.Floor;[BackgroundLifeProbe]::Pump(250)
 $lamp=$music.LampHandle;$target=[Windows.Interop.HwndSource]::FromHwnd($lamp).CompositionTarget
 $color=$target.BackgroundColor
 Check ($color.A-eq 145-and $color.R-eq 10-and $color.G-eq 7-and $color.B-eq 23) 'Native surface clears to transparent instead of retaining the room backdrop'
 $music.Motion.BeginHold();[BackgroundLifeProbe]::Pump(150)
 Check ($music.LampHandle-eq $lamp-and [BackgroundLifeProbe]::IsWindowVisible($lamp)) 'Pickup replaced or hid the background'
 # Character notification/topmost changes must not hide or raise the room.
 $cover=[Windows.Window]::new();$cover.Left=-5000;$cover.Top=-5000;$cover.Width=1000;$cover.Height=780;$cover.ShowActivated=$false;$cover.ShowInTaskbar=$false;$cover.Show()
 [BackgroundLifeProbe]::SetWindowPos($wh,[IntPtr](-1),0,0,0,0,0x213)|Out-Null
 [BackgroundLifeProbe]::Pump(250)
 Check ([BackgroundLifeProbe]::IsWindowVisible($lamp)) 'Character topmost transition hides the background'
 Check (([BackgroundLifeProbe]::GetLong($lamp,-20).ToInt64()-band 8)-eq 0) 'Room followed the character into the topmost band'
 Check ([GptWidgetZOrderNative]::PreviousVisible($hh)-eq $lamp) 'Background left its host layer'
 Check ([GptWidgetZOrderNative]::PreviousVisible($lamp)-ne $wh) 'Normal covering window was bypassed during reminder promotion'
 [BackgroundLifeProbe]::SetWindowPos($wh,[IntPtr](-2),0,0,0,0,0x213)|Out-Null;$cover.Close();$cover=$null
 Set-WidgetAboveHost $wh $hh $lamp|Out-Null;[BackgroundLifeProbe]::Pump(100)
 $music.SetVisibility($false,$false);Check (![BackgroundLifeProbe]::IsWindowVisible($lamp)) 'Host hide left its background visible'
 $music.SetVisibility($true,$false);[BackgroundLifeProbe]::Pump(100)
 Check ($music.LampHandle-eq $lamp-and [BackgroundLifeProbe]::IsWindowVisible($lamp)) 'Host resume recreated or failed to restore background'
 Check ([BackgroundLifeProbe]::GetLong($lamp,-8)-eq [IntPtr]::Zero) 'Background gained a native owner'
 $music.Stop($false);Check ($music.LampHandle-eq [IntPtr]::Zero-and ![BackgroundLifeProbe]::IsWindow($lamp)) 'Mode exit leaked the background surface'
 $currentForeground=[BackgroundLifeProbe]::GetForegroundWindow()
 Check ($currentForeground-ne $hh -and $currentForeground-ne $wh -and $currentForeground-ne $lamp) 'Test windows stole the foreground'
 $result=@{passed=($fail.Count-eq 0);failures=$fail;nativeClearColor=$color.ToString();scenarios=@('mode entry before landing','native background clear','pickup','temporary character topmost','covering window','host hide and resume','mode exit');testWindowsOffscreen=$true;observedUserWhiteFlashReproduced=$false}
 if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))}
 $result|ConvertTo-Json -Depth 5
 if($fail.Count){exit 1}
}finally{if($music){$music.Dispose()};if($follower){$follower.Dispose()};if($cover){$cover.Close()};if($window){$window.Close()};if($hostWindow){$hostWindow.Close()}}
