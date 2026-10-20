param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationCore,WindowsBase,System
$appDir=Split-Path $TestRoot -Parent
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $appDir 'runtime/audio.ps1'),[Text.Encoding]::UTF8)))
function Assert-Sound($Value,[string]$Message){if(!$Value){throw $Message}}
function Pump-Sound([int]$Milliseconds){
  $frame=[Windows.Threading.DispatcherFrame]::new();$timer=[Windows.Threading.DispatcherTimer]::new()
  $timer.Interval=[TimeSpan]::FromMilliseconds($Milliseconds)
  $timer.Add_Tick({$timer.Stop();$frame.Continue=$false}.GetNewClosure())
  $timer.Start();[Windows.Threading.Dispatcher]::PushFrame($frame)
}
function Pcm-Peak([byte[]]$Bytes){
  $offset=12
  while($offset+8-le $Bytes.Length){
    $name=[Text.Encoding]::ASCII.GetString($Bytes,$offset,4);$length=[int][BitConverter]::ToUInt32($Bytes,$offset+4)
    if($name-eq 'data'){
      $peak=0
      for($i=$offset+8;$i-lt $offset+8+$length;$i+=2){$peak=[Math]::Max($peak,[Math]::Abs([int][BitConverter]::ToInt16($Bytes,$i)))}
      return $peak
    }
    $offset+=8+$length+($length%2)
  }
  throw 'PCM fixture has no samples'
}
# Inject only the native call, so real queue/retry/pinning/cleanup paths are exercised.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public sealed class ClickAudioProbe {
 public volatile int Failures,Calls,Stops,LastByte;
 public bool ThrowFirst;
 public volatile bool FailStop;
 public ManualResetEvent Entered=new ManualResetEvent(false),Continue=new ManualResetEvent(true);
 public bool Play(IntPtr wave,uint flags){
  if(wave==IntPtr.Zero){Stops++;return !FailStop;}
  int call=++Calls;Entered.Set();Continue.WaitOne();
  LastByte=Marshal.ReadByte(wave);
  if(ThrowFirst && call==1)throw new InvalidOperationException("simulated device loss");
  if(Failures>0){Failures--;return false;}
  return true;
 }
 public Func<IntPtr,uint,bool> Callback {get{return Play;}}
}
'@
function Wait-Calls($Probe,[int]$Count){
  $deadline=[Diagnostics.Stopwatch]::StartNew()
  while($Probe.Calls-lt $Count -and $deadline.ElapsedMilliseconds-lt 2000){Start-Sleep -Milliseconds 5}
  Assert-Sound ($Probe.Calls-ge $Count) 'Audio worker did not process the command'
  # Wait for the success/error publication after entering the native callback.
  Start-Sleep -Milliseconds 30
}
foreach($throwFirst in @($false,$true)){
  $probe=[ClickAudioProbe]::new();$probe.Failures=if($throwFirst){0}else{1};$probe.ThrowFirst=$throwFirst
  $queue=[GptClickAudioQueue]::new($probe.Callback)
  try{
    $queue.Play([byte[]]@(1));Wait-Calls $probe 2
    Assert-Sound ($probe.Calls-eq 2 -and $probe.Stops-eq 1 -and !$queue.Error) 'First playback failure was not reset and retried once'
  }finally{$queue.Dispose();$queue.Wait(2000)}
  Assert-Sound (!$queue.IsRunning -and $probe.Stops-eq 2) 'Recovery worker retained its native buffer on exit'
}
$probe=[ClickAudioProbe]::new();$probe.Failures=10;$queue=[GptClickAudioQueue]::new($probe.Callback)
try{
  $queue.Play([byte[]]@(2));Wait-Calls $probe 2
  Assert-Sound ($probe.Calls-eq 2 -and $queue.Error) 'Persistent failure looped or was hidden'
  $probe.Failures=0;$queue.Play([byte[]]@(3));Wait-Calls $probe 3
  Assert-Sound ($probe.Calls-eq 3 -and !$queue.Error -and $probe.LastByte-eq 3) 'Next click did not recover after the device returned'
}finally{$queue.Dispose();$queue.Wait(2000)}
$probe=[ClickAudioProbe]::new();$null=$probe.Continue.Reset();$queue=[GptClickAudioQueue]::new($probe.Callback)
try{
  $queue.Play([byte[]]@(4))
  Assert-Sound ($probe.Entered.WaitOne(2000)) 'Blocked device fixture did not start'
  $clock=[Diagnostics.Stopwatch]::StartNew()
  for($i=0;$i-lt 120;$i++){$queue.Play([byte[]]@(5))}
  $queue.Play([byte[]]@(9));$clock.Stop()
  Assert-Sound ($clock.ElapsedMilliseconds-lt 300) 'Click delivery waited for the blocked driver'
  $null=$probe.Continue.Set();Wait-Calls $probe 2
  Assert-Sound ($probe.Calls-eq 2 -and $probe.LastByte-eq 9) 'Stale clicks accumulated or displaced the latest release'
}finally{$null=$probe.Continue.Set();$queue.Dispose();$queue.Wait(2000)}
Assert-Sound (!$queue.IsRunning) 'Blocked-device worker did not exit'
$queue.Play([byte[]]@(10));$queue.Stop();$queue.Dispose()
Assert-Sound ($probe.Calls-eq 2) 'A closed worker accepted stale commands'
$probe=[ClickAudioProbe]::new();$queue=[GptClickAudioQueue]::new($probe.Callback)
try{
  $queue.Play([byte[]]@(7));Wait-Calls $probe 1
  $probe.FailStop=$true;$queue.Play([byte[]]@(8));Start-Sleep -Milliseconds 80
  Assert-Sound ($queue.Error -and $probe.Calls-eq 1 -and $probe.Stops-eq 2) 'Failed stop freed/replaced active PCM or retried without a bound'
  $probe.FailStop=$false;$queue.Play([byte[]]@(8));Wait-Calls $probe 2
  Assert-Sound (!$queue.Error -and $probe.LastByte-eq 8) 'Playback did not recover after stop became available'
}finally{$probe.FailStop=$false;$queue.Dispose();$queue.Wait(2000)}
# A delayed old worker must not stop a newer settings/volume preview session.
$oldProbe=[ClickAudioProbe]::new();$null=$oldProbe.Continue.Reset();$oldQueue=[GptClickAudioQueue]::new($oldProbe.Callback)
$newProbe=[ClickAudioProbe]::new();$newQueue=[GptClickAudioQueue]::new($newProbe.Callback)
try{
  $oldQueue.Play([byte[]]@(1));Assert-Sound ($oldProbe.Entered.WaitOne(2000)) 'Old session did not start'
  $oldQueue.Dispose();$oldQueue.Wait(10);$newQueue.Play([byte[]]@(6))
  $null=$oldProbe.Continue.Set();Wait-Calls $newProbe 1;$oldQueue.Wait(2000)
  Assert-Sound (!$oldQueue.IsRunning -and !$newQueue.Error -and $newProbe.Stops-eq 0) 'Closing the old session stopped newer audio'
}finally{$null=$oldProbe.Continue.Set();$newQueue.Dispose();$newQueue.Wait(2000)}
Write-Output 'PASS: native false/exception retry, bounded failure, next-click recovery, 120 blocked-driver clicks, failed stop safety, session handoff and pinned-buffer shutdown'

$realFactory=${function:New-WidgetAudioClip}
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-sound-'+[Guid]::NewGuid().ToString('N'))
try{
  $original=[IO.File]::ReadAllBytes((Join-Path $appDir 'assets/press.wav'))
  $scaled=& $realFactory (Join-Path $appDir 'assets/press.wav') 0.37
  Assert-Sound ($scaled-is [byte[]] -and $scaled.Length-eq $original.Length) 'PCM clip did not preload'
  Assert-Sound ([Math]::Abs((Pcm-Peak $scaled)-(Pcm-Peak $original)*0.37)-le 1) 'Fractional volume did not scale the complete PCM samples'
  # Keep native PCM playback silent without changing system or user volume.
  $script:silentFactory=$realFactory
  function New-WidgetAudioClip([string]$Path,[double]$Volume){& $script:silentFactory $Path 0.0}
  $script:soundOn=$true;$script:soundVolume=0.9
  Initialize-WidgetAudio $appDir
  Assert-Sound ($null-ne $script:gptNiangAudio) 'System WAV backend did not initialize'
  Assert-Sound ((Pcm-Peak $script:gptNiangAudio.Press)-eq 0) 'Native playback fixture is not silent'
  for($i=0;$i-lt 120;$i++){Play-WidgetPressSound;Play-WidgetReleaseSound;Pump-Sound 2}
  for($i=0;$i-lt 3;$i++){
    Play-WidgetPressSound;Play-WidgetReleaseSound
    Pump-Sound ([int][Math]::Ceiling(($script:gptNiangAudio.Duration+0.1)*1000))
    Assert-Sound ($script:gptNiangAudio.ReleasePlayed -and !$script:gptNiangAudio.PendingRelease -and !$script:gptNiangAudio.Timer.IsEnabled) 'Rapid clicks left the next ordinary click pending'
  }
  Assert-Sound (!$script:gptNiangAudio.Queue.Error) 'Native PCM playback failed'
  Pump-Sound 5000
  Play-WidgetPressSound;Play-WidgetReleaseSound
  Pump-Sound ([int][Math]::Ceiling(($script:gptNiangAudio.Duration+0.1)*1000))
  Assert-Sound (!$script:gptNiangAudio.Queue.Error -and $script:gptNiangAudio.ReleasePlayed) 'Native playback did not resume after a five-second pause'
  $script:soundOn=$false;Play-WidgetPressSound
  Assert-Sound (!$script:gptNiangAudio.Pressing -and !$script:gptNiangAudio.Timer.IsEnabled) 'Muted clicks started the timer'
  $script:soundOn=$true;$script:soundVolume=0;Play-WidgetPressSound
  Assert-Sound (!$script:gptNiangAudio.Pressing) 'Zero volume started a pair'
  $script:soundVolume=0.37;Play-WidgetPressSound;Play-WidgetReleaseSound;Stop-WidgetAudio
  Assert-Sound (!$script:gptNiangAudio.PendingRelease -and !$script:gptNiangAudio.Timer.IsEnabled) 'Capture cancellation left a release pending'
  $oldAudio=$script:gptNiangAudio
  Initialize-WidgetAudio $appDir
  Assert-Sound (!$oldAudio.Press -and !$oldAudio.Release -and !$oldAudio.Queue.IsRunning -and !$oldAudio.Timer.IsEnabled) 'Reinitialization retained old streams or a timer'
  $fixtureAssets=Join-Path $fixtureRoot 'assets';$null=[IO.Directory]::CreateDirectory($fixtureAssets)
  Copy-Item -LiteralPath (Join-Path $appDir 'assets/press.wav') -Destination $fixtureAssets
  Initialize-WidgetAudio $fixtureRoot
  Assert-Sound ($null-eq $script:gptNiangAudio) 'Incomplete clip pair was accepted'
  Copy-Item -LiteralPath (Join-Path $appDir 'assets/release.wav') -Destination $fixtureAssets
  Initialize-WidgetAudio $fixtureRoot
  Assert-Sound ($null-ne $script:gptNiangAudio) 'Reinitialization did not recover a repaired clip pair'
  $lastAudio=$script:gptNiangAudio;Close-WidgetAudio
  Assert-Sound ($null-eq $script:gptNiangAudio -and !$lastAudio.Press -and !$lastAudio.Release -and !$lastAudio.Queue.IsRunning) 'Shutdown retained WAV resources'
  Write-Output 'PASS: PCM preload and native PlaySound recovery, fractional PCM volume, silent native 120 rapid clicks and three subsequent ordinary pairs, mute/zero/cancel, reinitialization, five-second pause, missing-file recovery and shutdown cleanup'
}finally{
  Close-WidgetAudio
  ${function:New-WidgetAudioClip}=$realFactory
  $resolved=[IO.Path]::GetFullPath($fixtureRoot);$allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
  if(!$resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved)-notlike 'gpt-niang-sound-*'){throw 'Unsafe sound fixture cleanup path'}
  if([IO.Directory]::Exists($resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
