param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
. (Join-Path (Split-Path $TestRoot -Parent) 'runtime\host-occlusion.ps1')
function Assert-Recovery($value,[string]$message){if(!$value){throw $message}}
# Exercise the production policy, including foreground events arriving before
# the real Z-order change. No mock timer or copy of the production source.
$policy=[GptCloakTransition]::new()
$policy.Begin(0)
Assert-Recovery ($policy.Sample(0,$false)-eq 0) 'Uncovered hosts must remain visible'
Assert-Recovery ($policy.Sample(32,$false)-eq 0 -and $policy.Active) 'Early matching snapshots must not end the transition burst'
Assert-Recovery ($policy.Sample(64,$true)-eq 1) 'Late real coverage must still be detected'
Assert-Recovery ($policy.Sample(96,$false)-eq 0) 'One exposure snapshot must not restore immediately'
Assert-Recovery ($policy.Sample(128,$false)-eq -1 -and !$policy.Active) 'Stable exposure must restore and stop checking'
$policy.Begin(200)
Assert-Recovery ($policy.Sample(200,$true)-eq 1) 'Covered hosts must cloak once'
Assert-Recovery ($policy.Sample(232,$true)-eq 0) 'Coverage must not repeatedly toggle the window'
Assert-Recovery ($policy.Sample(456,$true)-eq 0 -and !$policy.Active) 'Covered idle state must stop at the finite deadline'
$policy.Begin(500)
Assert-Recovery ($policy.Sample(500,$true)-eq 0) 'Logical foreground alone must not uncloak'
Assert-Recovery ($policy.Sample(532,$false)-eq 0) 'Exposure must settle before restoration'
Assert-Recovery ($policy.Sample(564,$false)-eq -1 -and !$policy.Active) 'Restoration must end the burst'
$policy.Begin(600)
for($n=600;$n-le 856;$n+=32){$null=$policy.Sample($n,(([int](($n-600)/32)%2)-eq 0))}
Assert-Recovery (!$policy.Active) 'Unstable switching must also have a finite budget'
$policy.Stop()
Assert-Recovery (!$policy.Active -and !$policy.Cloaked) 'Stop must clear transition state'
Write-Output 'PASS: production transition policy handles late Z-order, stable exposure and bounded bursts'

# All windows below belong to isolated test processes and are off-screen.
# Do not activate, inspect or manipulate the user''s ChatGPT window.
Add-Type -TypeDefinition @'
using System;using System.Collections.Generic;using System.Diagnostics;using System.Runtime.InteropServices;
public static class OcclusionTestNative {
 [DllImport("user32.dll")]public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags);

 public delegate void Callback(IntPtr hook,uint ev,IntPtr h,int obj,int child,uint thread,uint tick);
 [StructLayout(LayoutKind.Sequential)]struct Msg{public IntPtr h;public uint m;public UIntPtr w;public IntPtr l;public uint time;public int x,y;public uint reserved;}
 [DllImport("user32.dll")]public static extern IntPtr SetWinEventHook(uint first,uint last,IntPtr module,Callback callback,uint pid,uint thread,uint flags);
 [DllImport("user32.dll")]public static extern bool UnhookWinEvent(IntPtr hook);
 [DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")]public static extern IntPtr GetWindow(IntPtr h,uint command);
 [DllImport("user32.dll")]public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")]public static extern IntPtr GetLong(IntPtr h,int n);
 [DllImport("user32.dll",EntryPoint="SetWindowLongPtrW")]public static extern IntPtr SetLong(IntPtr h,int n,IntPtr v);
 [DllImport("user32.dll")]static extern bool PeekMessage(out Msg m,IntPtr h,uint a,uint b,uint flags);
 [DllImport("user32.dll")]static extern bool TranslateMessage(ref Msg m);
 [DllImport("user32.dll")]static extern IntPtr DispatchMessage(ref Msg m);
 [DllImport("user32.dll")]static extern uint MsgWaitForMultipleObjectsEx(uint n,IntPtr h,uint ms,uint mask,uint flags);
 [DllImport("dwmapi.dll")]public static extern int DwmGetWindowAttribute(IntPtr h,int attribute,out uint value,int size);
 public sealed class Row{public uint ev;public long hwnd;public int obj,child;}
 public static List<Row> Rows=new List<Row>();
 public static Callback Observer=delegate(IntPtr hook,uint ev,IntPtr h,int obj,int child,uint thread,uint tick){Rows.Add(new Row{ev=ev,hwnd=h.ToInt64(),obj=obj,child=child});};
 public static void Pump(int ms){var clock=Stopwatch.StartNew();while(clock.ElapsedMilliseconds<ms){Msg m;int n=0;while(n++<200&&PeekMessage(out m,IntPtr.Zero,0,0,1)){TranslateMessage(ref m);DispatchMessage(ref m);}MsgWaitForMultipleObjectsEx(0,IntPtr.Zero,10,0x4ff,4);}}
}
'@
function Wait-Recovery([scriptblock]$Condition,[string]$Message,[int]$Seconds=3){
 $deadline=[DateTime]::UtcNow.AddSeconds($Seconds)
 while(!(& $Condition)-and [DateTime]::UtcNow-lt $deadline){[OcclusionTestNative]::Pump(10)}
 Assert-Recovery (& $Condition) $Message
}
function New-RecoveryWindow([bool]$Transparent){
 $w=New-Object Windows.Window;$w.WindowStyle=[Windows.WindowStyle]::None;$w.ShowActivated=$false;$w.ShowInTaskbar=$false
 $w.Left=-10000;$w.Top=-10000;$w.Width=150;$w.Height=150
 $w.AllowsTransparency=$Transparent;$w.Background=if($Transparent){[Windows.Media.Brushes]::Transparent}else{[Windows.Media.Brushes]::White}
 $i=[Windows.Interop.WindowInteropHelper]::new($w);$h=$i.EnsureHandle()
 [OcclusionTestNative]::SetLong($h,-20,[IntPtr]([OcclusionTestNative]::GetLong($h,-20).ToInt64()-bor 0x08000080))|Out-Null
 return @{window=$w;interop=$i;handle=$h}
}
function Set-FixtureCoverage([string]$Mode){
 [IO.File]::WriteAllText((Join-Path $root 'request.txt'),$Mode)
 Wait-Recovery { (Get-Content -LiteralPath (Join-Path $root 'ack.txt') -Raw -ErrorAction SilentlyContinue)-eq $Mode } "Coverage fixture did not acknowledge $Mode"
 $recovery.OnWindowEvent([IntPtr]$ready.hwnd)
}
# Mirrors a cover window that closes/hides: its new geometry is applied without
# any WinEvent, so only the controller's own safety recheck can restore the pet.
function Set-FixtureCoverageSilent([string]$Mode){
 [IO.File]::WriteAllText((Join-Path $root 'request.txt'),$Mode)
 Wait-Recovery { (Get-Content -LiteralPath (Join-Path $root 'ack.txt') -Raw -ErrorAction SilentlyContinue)-eq $Mode } "Coverage fixture did not acknowledge $Mode"
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-occlusion-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$hostFixture=$null;$petFixture=$null;$child=$null;$recovery=$null
$hook=[IntPtr]::Zero;$messageHook=$null;$messageSource=$null
try{
 $foreground=[OcclusionTestNative]::GetForegroundWindow()
 $hostFixture=New-RecoveryWindow $false;$petFixture=New-RecoveryWindow $true
 $petFixture.interop.Owner=$hostFixture.handle
 $hostFixture.window.Show();$petFixture.window.Show();[OcclusionTestNative]::Pump(100)
 foreach($fixture in @($hostFixture,$petFixture)){
  Assert-Recovery ([OcclusionTestNative]::SetWindowPos($fixture.handle,[IntPtr]::Zero,-10000,-10000,150,150,0x14)) 'Physical-pixel test fixture placement failed'
 }
 $owner=[OcclusionTestNative]::GetWindow($petFixture.handle,4)
 $child=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoProfile','-STA','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $TestRoot 'fixtures\occlusion-cover.ps1')+'"'),'-Root',('"'+$root+'"')) -WindowStyle Hidden -PassThru
 Wait-Recovery {Test-Path -LiteralPath (Join-Path $root 'ready.json')} 'Foreign fixture did not start' 10
 $ready=Get-Content -LiteralPath (Join-Path $root 'ready.json') -Raw|ConvertFrom-Json
 Assert-Recovery ($ready.pid-eq $child.Id) 'Foreign fixture must have the expected process identity'
 $hook=[OcclusionTestNative]::SetWinEventHook(0x8017,0x8018,[IntPtr]::Zero,[OcclusionTestNative]::Observer,[uint32]$PID,0,0)
 Assert-Recovery ($hook-ne [IntPtr]::Zero) 'Real cloak event hook registration failed'
 $recovery=[GptWidgetOcclusionRecovery]::new($petFixture.handle)
 $messageSource=[Windows.Interop.HwndSource]::FromHwnd($petFixture.handle)
 $messageHook=[Windows.Interop.HwndSourceHook]{param($hwnd,$msg,$w,$l,[ref]$handled)if($msg-eq 0x47){$recovery.OnPositionChanged($l)};return [IntPtr]::Zero}
 $messageSource.AddHook($messageHook)
 $recovery.Configure($hostFixture.handle,$true)
 Wait-Recovery {$recovery.OwnedCloak -and !$recovery.Pending -and !$recovery.Failed} 'Full foreign coverage must cloak the pet and stop checking'
 $cloaked=0;$hr=[OcclusionTestNative]::DwmGetWindowAttribute($petFixture.handle,14,[ref]$cloaked,4)
 Assert-Recovery ($hr-eq 0 -and ($cloaked-band 1)-ne 0 -and [OcclusionTestNative]::IsWindowVisible($petFixture.handle)) 'Cloak must be real DWM state while preserving HWND visibility'
 $checks=$recovery.Checks;[OcclusionTestNative]::Pump(100)
 Assert-Recovery ($checks-eq $recovery.Checks) 'Covered idle burst must stop before the bounded safety recheck'
 # The P1 case: the cover disappears without a WinEvent. A stale DWM cloak
 # would leave the widget permanently invisible, so the bounded recheck must
 # restore it even though no event reached the controller.
 Set-FixtureCoverageSilent 'expose'
 Wait-Recovery {!$recovery.OwnedCloak -and !$recovery.Pending} 'Hidden cover without an event must be restored by the safety recheck' 3
 $uncloaked=0;$hr=[OcclusionTestNative]::DwmGetWindowAttribute($petFixture.handle,14,[ref]$uncloaked,4)
 Assert-Recovery ($hr-eq 0 -and $uncloaked-eq 0) 'Safety recheck must clear the real DWM cloak'
 Set-FixtureCoverage 'full'
 Wait-Recovery {$recovery.OwnedCloak -and !$recovery.Pending} 'Repeated full coverage after the safety restore must cloak again'
 Set-FixtureCoverage 'expose'
 Wait-Recovery {!$recovery.OwnedCloak -and !$recovery.Pending} 'Real exposure must uncloak after stable exposure'
 $uncloaked=0;$hr=[OcclusionTestNative]::DwmGetWindowAttribute($petFixture.handle,14,[ref]$uncloaked,4)
 Assert-Recovery ($hr-eq 0 -and $uncloaked-eq 0) 'Restoration must clear actual DWM cloak'
 foreach($eventId in @(0x8017,0x8018)){
  Assert-Recovery (@([OcclusionTestNative]::Rows|Where-Object {$_.hwnd-eq $petFixture.handle.ToInt64() -and $_.ev-eq $eventId -and $_.obj-eq 0 -and $_.child-eq 0}).Count-ge 1) 'Controller must emit real system CLOAKED and UNCLOAKED events'
 }
 Set-FixtureCoverage 'partial'
 Wait-Recovery {!$recovery.OwnedCloak -and !$recovery.Pending} 'Partial overlap must retain the pet'
 $blocked=$false;try{$invalid=[GptWidgetOcclusionRecovery]::new([IntPtr]$ready.hwnd)}catch{$blocked=$true}
 Assert-Recovery $blocked 'Controller must reject mutating a foreign process HWND'
 Set-FixtureCoverage 'full'
 Wait-Recovery {$recovery.OwnedCloak -and !$recovery.Pending} 'Repeated coverage must work with the native message hook attached'
 $recovery.Configure($hostFixture.handle,$false)
 Assert-Recovery (!$recovery.OwnedCloak -and !$recovery.Pending) 'Leaving follow mode must restore visibility and stop timers'
 $checks=$recovery.Checks;[OcclusionTestNative]::Pump(100)
 Assert-Recovery ($checks-eq $recovery.Checks) 'Disabled controller must not poll'
 $recovery.Configure($hostFixture.handle,$true)
 Wait-Recovery {$recovery.OwnedCloak -and !$recovery.Pending} 'Re-entering follow mode must work'
 $recovery.Dispose()
 $uncloaked=0;$hr=[OcclusionTestNative]::DwmGetWindowAttribute($petFixture.handle,14,[ref]$uncloaked,4)
 Assert-Recovery ($hr-eq 0 -and $uncloaked-eq 0 -and !$recovery.Pending) 'Dispose must restore its own cloak and stop checking'
 $currentForeground=[OcclusionTestNative]::GetForegroundWindow()
 Assert-Recovery ([OcclusionTestNative]::GetWindow($petFixture.handle,4)-eq $owner) 'Owner must remain unchanged'
 Assert-Recovery ($currentForeground-ne $petFixture.handle -and $currentForeground-ne $hostFixture.handle) 'Test windows must not steal the foreground'
 Write-Output 'PASS: real foreign coverage, native cloak events, hidden-cover safety restore, partial overlap, owner/foreground preservation, cleanup and no idle polling'
}finally{
 if($recovery){$recovery.Dispose()}
 if($messageHook -and $messageSource){$messageSource.RemoveHook($messageHook)}
 if($hook-ne [IntPtr]::Zero){[OcclusionTestNative]::UnhookWinEvent($hook)|Out-Null}
 [IO.File]::WriteAllText((Join-Path $root 'stop.flag'),'stop')
 if($child){$child.WaitForExit(3000)|Out-Null;if(!$child.HasExited){$child.Kill()};$child.Dispose()}
 if($petFixture){$petFixture.window.Close()};if($hostFixture){$hostFixture.window.Close()}
 foreach($name in @('ready.json','request.txt','ack.txt','stop.flag')){Remove-Item -LiteralPath (Join-Path $root $name) -ErrorAction SilentlyContinue}
 Remove-Item -LiteralPath $root
}
