param([string]$ResultFile)
$ErrorActionPreference='Stop'
$script:appDir=Split-Path $PSScriptRoot -Parent
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime/music.ps1'),[Text.Encoding]::UTF8)))
Initialize-WidgetMusicTypes
. (Join-Path $script:appDir 'runtime/host-follow.ps1')
Add-Type -ReferencedAssemblies @('System.dll',[Windows.Threading.DispatcherTimer].Assembly.Location) -TypeDefinition @'
using System;using System.Diagnostics;using System.Runtime.InteropServices;using System.Windows.Threading;
public static class MusicDispatchProbe {
 [StructLayout(LayoutKind.Sequential)]public struct Rect{public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")]public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int z,uint flags);
 [DllImport("user32.dll")]static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")]static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 public static bool Pump(int milliseconds){
  var frame=new DispatcherFrame();var timer=new DispatcherTimer();var clock=Stopwatch.StartNew();bool own=false;
  EventHandler tick=delegate(object sender,EventArgs e){uint pid;GetWindowThreadProcessId(GetForegroundWindow(),out pid);own|=pid==(uint)Process.GetCurrentProcess().Id;if(clock.Elapsed.TotalMilliseconds>=milliseconds){timer.Stop();frame.Continue=false;}};
  timer.Interval=TimeSpan.FromMilliseconds(8);timer.Tick+=tick;
  try{timer.Start();Dispatcher.PushFrame(frame);}finally{timer.Stop();timer.Tick-=tick;}
  return own;
 }
}
'@
function Bounds([IntPtr]$Handle){$r=New-Object MusicDispatchProbe+Rect;[MusicDispatchProbe]::GetWindowRect($Handle,[ref]$r)|Out-Null;return $r}
$window=$null;$hostWindow=$null;$follower=$null;$music=$null;$activation=$false
try{
 $hostWindow=[Windows.Window]::new();$hostWindow.Width=1000;$hostWindow.Height=780;$hostWindow.Left=160;$hostWindow.Top=100
 $hostWindow.WindowStyle='None';$hostWindow.ShowActivated=$false;$hostWindow.ShowInTaskbar=$false;$hostWindow.Show()
 $hostHandle=[Windows.Interop.WindowInteropHelper]::new($hostWindow).Handle
 $window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $script:appDir 'widget.xaml'),[Text.Encoding]::UTF8))
 $window.Width=$window.Height=378;$window.Left=260;$window.Top=160
 $girl=$window.FindName('Girl');$girl.Source=[Windows.Media.Imaging.BitmapImage]::new([Uri](Join-Path $script:appDir 'assets/gpt-dragon-niang-bust.png'))
 foreach($part in @('Bubble','Tail','TailNear')){$window.FindName($part).Visibility='Collapsed'}
 $window.Show();$widgetHandle=[Windows.Interop.WindowInteropHelper]::new($window).Handle
 $activation=[MusicDispatchProbe]::Pump(80)-or $activation
 $hostBounds=Bounds $hostHandle;$original=Bounds $widgetHandle
 $follower=[GptWidgetHostFollower]::new($widgetHandle)
 $follower.Configure($hostHandle,$hostBounds.Left,$hostBounds.Top,$hostBounds.Right,$hostBounds.Bottom,($original.Right-$original.Left),($original.Bottom-$original.Top),($original.Left-$hostBounds.Left),0,($hostBounds.Bottom-$original.Bottom),'free',$true)
 $move=[Delegate]::CreateDelegate([Action[int,int]],$follower,'SetTemporaryOffset')
 $palette=[Windows.Media.Color[]]@('#D773AD','#9A79DC','#579DCF','#43AE94','#DBA15C','#D773AD'|ForEach-Object{[Windows.Media.ColorConverter]::ConvertFromString($_)})
 $music=[GptMusicVisual]::new($window,$girl,$window.FindName('Bubble'),$move,$palette,$true)
 $music.FollowLamp=[Delegate]::CreateDelegate([Action[IntPtr,int,int,int]],$follower,'SetCompanion')
 $music.HostFrame=[Delegate]::CreateDelegate([Func[int[]]],$follower,'GetFrame')
 $music.Configure($widgetHandle,$hostHandle,$true,$true,$false,$false,$original.Left,$original.Top,$hostBounds.Left,$hostBounds.Bottom,1.25)
 $music.Motion.BeginHold();$music.Motion.X=$music.Motion.Width*.5;$music.Motion.Y=$music.Motion.Floor-180
 $activation=[MusicDispatchProbe]::Pump(80)-or $activation
 $request=[GptMusicVisual].GetMethod('RequestPosition',[Reflection.BindingFlags]'Instance,NonPublic')
 $pendingField=[GptMusicVisual].GetField('pendingPosition',[Reflection.BindingFlags]'Instance,NonPublic')
 if(!$request-or !$pendingField){throw 'Deferred music position delivery is missing'}
 $before=Bounds $widgetHandle
 $music.Motion.X+=50;$request.Invoke($music,@())|Out-Null;$pending=$pendingField.GetValue($music)
 for($i=0;$i-lt 20;$i++){$request.Invoke($music,@())|Out-Null;if(![object]::ReferenceEquals($pending,$pendingField.GetValue($music))){throw 'Position requests were not coalesced'}}
 [MusicDispatchProbe]::SetWindowPos($hostHandle,[IntPtr]::Zero,($hostBounds.Left+80),($hostBounds.Top+60),0,0,0x215)|Out-Null
 $null=$follower.Synchronize();$activation=[MusicDispatchProbe]::Pump(80)-or $activation
 $after=Bounds $widgetHandle
 if([Math]::Abs($after.Left-$before.Left-130)-gt 1-or [Math]::Abs($after.Top-$before.Top-60)-gt 1){throw ('Queued move used a stale host frame: '+$before.Left+','+$before.Top+' -> '+$after.Left+','+$after.Top)}
 # A bubble can open after a render requested a position, before delivery.
 $music.Motion.Release();$music.Motion.Phase=2;$music.Motion.Y=$music.Motion.Floor
 $window.FindName('Bubble').Visibility='Visible';$before=Bounds $widgetHandle;$music.Motion.X+=50
 $apply=[GptMusicVisual].GetMethod('ApplyPosition',[Reflection.BindingFlags]'Instance,NonPublic')
 $apply.Invoke($music,@())|Out-Null;$after=Bounds $widgetHandle
 if($before.Left-ne $after.Left-or $before.Top-ne $after.Top){throw 'Position delivery ignored a newly opened bubble'}
 $window.FindName('Bubble').Visibility='Collapsed';$music.Motion.BeginHold()
 $before=Bounds $widgetHandle;$music.Motion.X+=80;$request.Invoke($music,@())|Out-Null
 $music.SetVisibility($false,$false);$activation=[MusicDispatchProbe]::Pump(80)-or $activation
 $after=Bounds $widgetHandle
 if($before.Left-ne $after.Left-or $before.Top-ne $after.Top){throw 'Queued movement ran after visibility was disabled'}
 $music.SetVisibility($true,$false);$activation=[MusicDispatchProbe]::Pump(80)-or $activation
 $request.Invoke($music,@())|Out-Null;$stopPending=$pendingField.GetValue($music)
 $music.Stop($false)
 if($stopPending.Status-ne 'Aborted'){throw 'Music stop did not abort queued movement'}
 $activation=[MusicDispatchProbe]::Pump(80)-or $activation
 $restored=Bounds $widgetHandle
 if($restored.Left-ne $original.Left+80-or $restored.Top-ne $original.Top+60){throw 'A queued move overwrote normal placement after stop'}
 if($activation){throw 'An isolated music test window became the foreground application'}
 $result=@{passed=$true;coalescedRequests=21;usesLatestHostFrame=$true;currentInteractionRespected=$true;hiddenDeliverySkipped=$true;stopAbortsPending=$true;normalPositionRestored=$true;testWindowsNeverActivated=$true}
 if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))}
 Write-Output 'PASS: coalesced native follow updates, latest host frame, hidden delivery skipped, stop cancellation and normal placement restoration'
}finally{if($music){$music.Dispose()};if($follower){$follower.Dispose()};foreach($w in @($window,$hostWindow)){if($w){$w.Close()}}}
