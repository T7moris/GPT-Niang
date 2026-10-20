param([string]$ResultFile)
$ErrorActionPreference='Stop';$app=Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
. (Join-Path $app 'runtime/host-follow.ps1')
Add-Type -ReferencedAssemblies @('System.dll',[Windows.Window].Assembly.Location) -TypeDefinition @'
using System;using System.Runtime.InteropServices;using System.Windows.Interop;
public static class MusicMoveMessages {
 public static int Before,After;
 [StructLayout(LayoutKind.Sequential)]public struct Rect{public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out Rect r);
 public static IntPtr Hook(IntPtr h,int msg,IntPtr w,IntPtr l,ref bool handled){if(msg==0x46)Before++;if(msg==0x47)After++;return IntPtr.Zero;}
}
'@
$hostWindow=$null;$widgetWindow=$null;$follower=$null;$source=$null
try{
 $hostWindow=[Windows.Window]::new();$hostWindow.Width=1000;$hostWindow.Height=700;$hostWindow.Left=180;$hostWindow.Top=100;$hostWindow.ShowActivated=$false;$hostWindow.ShowInTaskbar=$false;$hostWindow.Show()
 $widgetWindow=[Windows.Window]::new();$widgetWindow.WindowStyle='None';$widgetWindow.AllowsTransparency=$true;$widgetWindow.Background=[Windows.Media.Brushes]::Transparent;$widgetWindow.Width=180;$widgetWindow.Height=180;$widgetWindow.Left=280;$widgetWindow.Top=200;$widgetWindow.ShowActivated=$false;$widgetWindow.ShowInTaskbar=$false;$widgetWindow.Show()
 $hostHandle=[Windows.Interop.WindowInteropHelper]::new($hostWindow).Handle;$widgetHandle=[Windows.Interop.WindowInteropHelper]::new($widgetWindow).Handle
 $source=[Windows.Interop.HwndSource]::FromHwnd($widgetHandle);$hook=[Delegate]::CreateDelegate([Windows.Interop.HwndSourceHook],[MusicMoveMessages].GetMethod('Hook'));$source.AddHook($hook)
 $h=New-Object MusicMoveMessages+Rect;$w=New-Object MusicMoveMessages+Rect;[MusicMoveMessages]::GetWindowRect($hostHandle,[ref]$h)|Out-Null;[MusicMoveMessages]::GetWindowRect($widgetHandle,[ref]$w)|Out-Null
 $follower=[GptWidgetHostFollower]::new($widgetHandle);$follower.Configure($hostHandle,$h.Left,$h.Top,$h.Right,$h.Bottom,($w.Right-$w.Left),($w.Bottom-$w.Top),($w.Left-$h.Left+30),0,($h.Bottom-$w.Bottom),'free',$true)
 if([MusicMoveMessages]::Before-lt 1){throw 'Ordinary synchronization unexpectedly suppressed its original notification'}
 $ordinaryBefore=[MusicMoveMessages]::Before;[MusicMoveMessages]::Before=0;[MusicMoveMessages]::After=0
 $before=New-Object MusicMoveMessages+Rect;[MusicMoveMessages]::GetWindowRect($widgetHandle,[ref]$before)|Out-Null
 $sw=[Diagnostics.Stopwatch]::StartNew();$follower.SetTemporaryOffset(40,25);$moveMs=$sw.Elapsed.TotalMilliseconds
 $after=New-Object MusicMoveMessages+Rect;[MusicMoveMessages]::GetWindowRect($widgetHandle,[ref]$after)|Out-Null
 if($after.Left-ne $before.Left+40-or $after.Top-ne $before.Top+25-or $after.Right-$after.Left-ne $before.Right-$before.Left-or $after.Bottom-$after.Top-ne $before.Bottom-$before.Top){throw 'Music native move changed the wrong position or size'}
 if([MusicMoveMessages]::Before-ne 0-or [MusicMoveMessages]::After-lt 1){throw 'Music move entered the pre-move render barrier, or suppressed the final position notification'}
 $result=@{passed=$true;ordinaryNotificationCount=$ordinaryBefore;musicBeforeNotification=[MusicMoveMessages]::Before;musicAfterNotification=[MusicMoveMessages]::After;musicMoveMs=$moveMs;nativePositionUpdatedSynchronously=$true;nativeSizePreserved=$true}
 if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))}
 Write-Output 'PASS: only music bypasses the pre-move render barrier; ordinary synchronization, final position notification and native size preserved'
}finally{if($source-and $hook){$source.RemoveHook($hook)};if($follower){$follower.Dispose()};if($widgetWindow){$widgetWindow.Close()};if($hostWindow){$hostWindow.Close()}}
