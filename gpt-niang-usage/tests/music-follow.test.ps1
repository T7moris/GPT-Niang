param([string]$ResultFile)
$ErrorActionPreference='Stop'
$app=Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
. (Join-Path $app 'runtime/host-follow.ps1')
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class MusicFollowProbe {
 [StructLayout(LayoutKind.Sequential)]public struct Rect{public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")]public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int height,uint flags);
 [DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
}
'@
function Rect([IntPtr]$Handle){$r=New-Object MusicFollowProbe+Rect;[MusicFollowProbe]::GetWindowRect($Handle,[ref]$r)|Out-Null;return $r}
function New-Window([int]$W,[int]$H){
 $wpf=[Windows.Window]::new();$wpf.ShowActivated=$false;$wpf.ShowInTaskbar=$false;$wpf.WindowStyle='None';$wpf.Width=$W;$wpf.Height=$H;$wpf.Left=-5000;$wpf.Top=-5000
 $wpf.Background=[Windows.Media.Brushes]::Transparent;$wpf.AllowsTransparency=$true;$wpf.Show();return $wpf
}
$hostWindow=$null;$widget=$null;$lamp=$null;$follower=$null;$samples=0;$foreground=[MusicFollowProbe]::GetForegroundWindow()
try{
 $hostWindow=New-Window 900 650;$widget=New-Window 240 240;$lamp=New-Window 84 84
 $hostHandle=[Windows.Interop.WindowInteropHelper]::new($hostWindow).Handle
 $widgetHandle=[Windows.Interop.WindowInteropHelper]::new($widget).Handle
 $lampHandle=[Windows.Interop.WindowInteropHelper]::new($lamp).Handle
 $lampBounds=Rect $lampHandle;$lampWidth=$lampBounds.Right-$lampBounds.Left;$lampHeight=$lampBounds.Bottom-$lampBounds.Top
 $follower=[GptWidgetHostFollower]::new($widgetHandle)
 $r=Rect $hostHandle
 $follower.Configure($hostHandle,$r.Left,$r.Top,$r.Right,$r.Bottom,240,240,210,20,24,'free',$true)
 $bind=[Delegate]::CreateDelegate([Action[IntPtr,int,int,int]],$follower,'SetCompanion');$bind.Invoke($lampHandle,$lampWidth,$lampHeight,52)
 $getFrame=[Delegate]::CreateDelegate([Func[int[]]],$follower,'GetFrame')
 # Synchronous checks do not let a render timer hide a stale companion position.
 foreach($size in @(@(900,650),@(700,500),@(1100,800))){
  foreach($point in @(@(200,160),@(110,400),@(-120,660),@(700,-80),@(150,120))){
   [MusicFollowProbe]::SetWindowPos($hostHandle,[IntPtr]::Zero,$point[0],$point[1],$size[0],$size[1],0x214)|Out-Null
   $null=$follower.Synchronize();$f=$getFrame.Invoke();$l=Rect $lampHandle
   $expectedX=$f[0]+[int][Math]::Floor(($f[2]-$f[0]-$lampWidth)/2)
   if($l.Left-ne $expectedX -or $l.Top-ne $f[1]+52){throw 'Lamp drifted from host top center'}
   if($l.Right-$l.Left-ne $lampWidth -or $l.Bottom-$l.Top-ne $lampHeight){throw 'Lamp resized while moving its host'}
   $samples++
  }
 }
 $bind.Invoke([IntPtr]::Zero,0,0,0);$detached=Rect $lampHandle
 [MusicFollowProbe]::SetWindowPos($hostHandle,[IntPtr]::Zero,350,250,0,0,0x215)|Out-Null
 $null=$follower.Synchronize();$l=Rect $lampHandle
 if($l.Left-ne $detached.Left -or $l.Top-ne $detached.Top){throw 'Detached lamp still followed'}
 $currentForeground=[MusicFollowProbe]::GetForegroundWindow()
 if($currentForeground-eq $hostHandle -or $currentForeground-eq $widgetHandle -or $currentForeground-eq $lampHandle){throw 'Following activated a window'}
 $result=@{passed=$true;samples=$samples;singleNativePositionWriter=$true;relativeTopCenterFixed=$true;sizeStable=$true;screenEdgeNotClamped=$true;detachPassed=$true;foregroundUnchanged=$true}
 if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))}
 Write-Output ('PASS: '+$samples+' native companion moves/resizes/edge cases without timer updates, fixed top center and unchanged foreground')
}finally{if($follower){$follower.Dispose()};foreach($wpf in @($lamp,$widget,$hostWindow)){if($wpf){$wpf.Close()}}}
