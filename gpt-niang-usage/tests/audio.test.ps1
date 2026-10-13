param([switch]$SkipNative)
$ErrorActionPreference='Stop'
$appDir=Split-Path $PSScriptRoot -Parent
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $appDir 'runtime\audio.ps1'),[Text.Encoding]::UTF8)))
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
function Assert-Audio($Condition,[string]$Message){if(!$Condition){throw $Message}}
function Pump-Audio([int]$Milliseconds){
    $frame=[Windows.Threading.DispatcherFrame]::new();$timer=[Windows.Threading.DispatcherTimer]::new()
    $timer.Interval=[TimeSpan]::FromMilliseconds($Milliseconds)
    $timer.Add_Tick({$timer.Stop();$frame.Continue=$false}.GetNewClosure())
    $timer.Start();[Windows.Threading.Dispatcher]::PushFrame($frame)
}
function Get-NativeAudioHeader($Engine,[string]$Name){
    $flags=[Reflection.BindingFlags]'Instance,NonPublic'
    $buffer=$Engine.GetType().GetField($Name,$flags).GetValue($Engine)
    $pointer=$buffer.GetType().GetField('Header').GetValue($buffer)
    $type=$Engine.GetType().GetNestedType('WaveHeader',[Reflection.BindingFlags]::NonPublic)
    return [Runtime.InteropServices.Marshal]::PtrToStructure([IntPtr]$pointer,[type]$type)
}
function Assert-NativeAudioSilent($Engine,[string]$Name){
    $header=Get-NativeAudioHeader $Engine $Name
    $bytes=New-Object byte[] ([int]$header.Length)
    [Runtime.InteropServices.Marshal]::Copy($header.Data,$bytes,0,$bytes.Length)
    Assert-Audio ($bytes.Length-gt 1000) 'A truncated PCM buffer was submitted'
    Assert-Audio (@($bytes|Where-Object{$_-ne 0}).Count-eq 0) 'Native stress test would emit an audible sample'
}
$script:soundOn=$true;$script:soundVolume=0.9
$realEngineFactory=${function:New-WidgetAudioEngine}
try{
    if(!$SkipNative){
        $canPlay=$true
        try{$native=New-WidgetAudioEngine $appDir}
        catch{
            if($_.Exception.Message-match 'Open click audio failed'){Write-Output 'SKIP: no usable native PCM output device';$canPlay=$false}
            else{throw}
        }
        if($canPlay){
            $native.IsMuted=$true
            try{
                $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(8)
                $script:gptNiangAudio=@{AppDir=$appDir;Engine=$native;Timer=$timer;Pressing=$false;PressEnded=$true;PendingRelease=$false;ReleasePlayed=$true;Faulted=$false;RetryClock=[Diagnostics.Stopwatch]::new();PlaybackClock=[Diagnostics.Stopwatch]::new()}
                $timer.Add_Tick({Update-WidgetAudio})
                $originalEngine=$native;$originalHandle=$native.GetType().GetField('device',[Reflection.BindingFlags]'Instance,NonPublic').GetValue($native)
                # Cancel inside the press, near its boundary, and during the release.
                foreach($delay in @(1,8,24,90,130,170,220,310)){
                    Play-WidgetPressSound;Play-WidgetReleaseSound;Pump-Audio $delay
                    Assert-Audio (!$script:gptNiangAudio.Faulted) ('Native restart failed after '+$delay+'ms')
                }
                for($i=0;$i-lt 120;$i++){
                    Play-WidgetPressSound;Play-WidgetReleaseSound;Pump-Audio (@(1,5,11)[$i%3])
                    Assert-Audio (!$script:gptNiangAudio.Faulted) 'Fast clicks left the native engine faulted'
                }
                # Slowing down must yield complete pairs after a long rapid sequence.
                for($i=0;$i-lt 8;$i++){
                    Play-WidgetPressSound;Play-WidgetReleaseSound
                    $deadline=[Diagnostics.Stopwatch]::StartNew()
                    while(!$script:gptNiangAudio.ReleasePlayed -and $deadline.ElapsedMilliseconds-lt 2000){Pump-Audio 4}
                    Assert-Audio ($script:gptNiangAudio.ReleasePlayed -and !$script:gptNiangAudio.Faulted) 'Press did not complete before release on a subsequent slow click'
                    $press=Get-NativeAudioHeader $native 'press'
                    Assert-Audio (($press.Flags-band 1)-ne 0) 'Release started without driver-completed press PCM'
                    Assert-NativeAudioSilent $native 'press';Assert-NativeAudioSilent $native 'release'
                    Pump-Audio 220
                    $release=Get-NativeAudioHeader $native 'release'
                    Assert-Audio (($release.Flags-band 1)-ne 0) 'Release buffer did not complete on a subsequent slow click'
                }
                Assert-Audio ([object]::ReferenceEquals($native,$originalEngine)) 'Normal clicks recreated the PCM player'
                Assert-Audio ($native.GetType().GetField('device',[Reflection.BindingFlags]'Instance,NonPublic').GetValue($native)-eq $originalHandle) 'Normal clicks reopened the native device'
                Play-WidgetPressSound;Play-WidgetReleaseSound;Pump-Audio 4
                Write-Output 'PASS: silent actual PCM output, eight boundary restarts, 120 fast clicks then eight complete slow pairs, one reused device, full submitted buffers and driver completion'
            }finally{Close-WidgetAudio}
            Assert-Audio ($null-eq $script:gptNiangAudio) 'Shutdown left an active controller'
            Assert-Audio ($native.GetType().GetField('device',[Reflection.BindingFlags]'Instance,NonPublic').GetValue($native)-eq [IntPtr]::Zero) 'Shutdown did not close the output device'
        }
    }
    Add-Type -TypeDefinition @'
using System;
public sealed class WidgetAudioTestEngine {
    public bool PressCompleted, FailPress, FailRelease, FailStop, FailDispose, Disposed;
    public int PressStarts, ReleaseStarts, Stops, Disposes;
    public double LastPressVolume, LastReleaseVolume;
    public void Stop() { Stops++; if(FailStop) throw new InvalidOperationException("Persistent reset failure"); PressCompleted=false; }
    public void StartPress(double volume) { if(FailPress) throw new InvalidOperationException("Persistent press failure"); PressStarts++; PressCompleted=false; LastPressVolume=volume; }
    public void StartRelease(double volume) { if(FailRelease) throw new InvalidOperationException("Release failure"); if(!PressCompleted) throw new InvalidOperationException("Incomplete press"); ReleaseStarts++; LastReleaseVolume=volume; }
    public void Dispose() { Disposes++; Disposed=true; if(FailDispose) throw new InvalidOperationException("Cleanup still playing"); }
}
'@
    function New-TestAudioTimer {
        $timer=[pscustomobject]@{Starts=0;Stops=0}
        $timer|Add-Member ScriptMethod Start {$this.Starts++}
        $timer|Add-Member ScriptMethod Stop {$this.Stops++}
        return $timer
    }
    function New-TestAudio($Engine){
        return @{AppDir=$appDir;Engine=$Engine;Timer=(New-TestAudioTimer);Pressing=$false;PressEnded=$true;PendingRelease=$false;ReleasePlayed=$true;Faulted=$false;RetryClock=[Diagnostics.Stopwatch]::new();PlaybackClock=[Diagnostics.Stopwatch]::new()}
    }
    $engine=[WidgetAudioTestEngine]::new();$script:gptNiangAudio=New-TestAudio $engine
    Play-WidgetPressSound;Play-WidgetReleaseSound
    # Model a slow driver/decoder: longer than the old 130ms+60ms wall-clock fallback.
    Start-Sleep -Milliseconds 240;Update-WidgetAudio
    Assert-Audio ($engine.ReleaseStarts-eq 0 -and $script:gptNiangAudio.PendingRelease) 'Slow startup truncated press and advanced to release'
    $engine.PressCompleted=$true;Update-WidgetAudio;Update-WidgetAudio
    Assert-Audio ($engine.ReleaseStarts-eq 1) 'Completed press must join release exactly once'
    Play-WidgetPressSound;Play-WidgetReleaseSound
    Update-WidgetAudio # A previously queued tick must inspect the current incomplete buffer.
    Assert-Audio ($engine.ReleaseStarts-eq 1) 'An old timer tick released the new incomplete press'
    $engine.PressCompleted=$true;Update-WidgetAudio
    Assert-Audio ($engine.ReleaseStarts-eq 2) 'A subsequent pair did not recover'
    Play-WidgetPressSound;$engine.PressCompleted=$true;Update-WidgetAudio
    Assert-Audio ($engine.ReleaseStarts-eq 2 -and $script:gptNiangAudio.Pressing) 'Long hold played release before mouse-up'
    Play-WidgetReleaseSound
    Assert-Audio ($engine.ReleaseStarts-eq 3) 'Long hold did not release after mouse-up'
    Play-WidgetPressSound;Play-WidgetReleaseSound;Stop-WidgetAudio;$engine.PressCompleted=$true;Update-WidgetAudio
    Assert-Audio ($engine.ReleaseStarts-eq 3 -and !$script:gptNiangAudio.PendingRelease) 'Capture loss played a cancelled release'
    $oldAudio=$script:gptNiangAudio;$oldEngine=$engine
    Close-WidgetAudio;$engine=[WidgetAudioTestEngine]::new();$script:gptNiangAudio=New-TestAudio $engine
    Play-WidgetPressSound;Play-WidgetReleaseSound;$oldEngine.PressCompleted=$true;Update-WidgetAudio $oldAudio
    Assert-Audio ($engine.ReleaseStarts-eq 0) 'A disposed instance completed the current pair'
    $engine.PressCompleted=$true;Update-WidgetAudio
    Assert-Audio ($engine.ReleaseStarts-eq 1) 'A fresh instance did not complete its own pair'
    $script:soundOn=$false;Play-WidgetPressSound;Play-WidgetReleaseSound
    Assert-Audio ($engine.PressStarts-eq 1 -and $engine.ReleaseStarts-eq 1) 'Disabled sound still played'
    $script:soundOn=$true;$script:soundVolume=0;Play-WidgetPressSound;Play-WidgetReleaseSound
    Assert-Audio ($engine.PressStarts-eq 1) 'Zero volume still submitted sound'
    $script:soundVolume=0.35;Play-WidgetPressSound
    Assert-Audio ([Math]::Abs($engine.LastPressVolume-0.35)-lt 0.0000001) 'Fractional press volume was rounded'
    Play-WidgetReleaseSound;Set-WidgetAudioVolume 0;$engine.PressCompleted=$true;Update-WidgetAudio
    Assert-Audio ($engine.ReleaseStarts-eq 1) 'Muting mid-press left a pending release'
    $script:soundVolume=0.9
    $script:factoryCalls=0
    function New-WidgetAudioEngine([string]$AppDir){$script:factoryCalls++;return [WidgetAudioTestEngine]::new()}
    # A persistent press failure must cancel release, discard the bad engine and recover.
    $bad=[WidgetAudioTestEngine]::new();$bad.FailPress=$true;$script:gptNiangAudio=New-TestAudio $bad
    for($i=0;$i-lt 5;$i++){Play-WidgetPressSound;Play-WidgetReleaseSound;Update-WidgetAudio}
    Assert-Audio ($bad.ReleaseStarts-eq 0 -and $bad.Disposed) 'Persistent press failure left release-only playback'
    Assert-Audio ($script:factoryCalls-eq 0) 'Rapid clicks repeatedly reopened a failed device'
    $script:gptNiangAudio.RetryClock.Reset();Play-WidgetPressSound;Play-WidgetReleaseSound
    $recovered=$script:gptNiangAudio.Engine;$recovered.PressCompleted=$true;Update-WidgetAudio
    Assert-Audio ($recovered.PressStarts-eq 1 -and $recovered.ReleaseStarts-eq 1 -and $script:factoryCalls-eq 1) 'A slow click after persistent failure did not restore the whole pair'
    # Release/stop errors also cancel this pair and allow later complete playback.
    foreach($failure in @('FailRelease','FailStop')){
        $broken=[WidgetAudioTestEngine]::new();$script:gptNiangAudio=New-TestAudio $broken
        if($failure-eq 'FailStop'){$broken.FailStop=$true;Play-WidgetPressSound}
        else{Play-WidgetPressSound;Play-WidgetReleaseSound;$broken.PressCompleted=$true;$broken.FailRelease=$true;Update-WidgetAudio}
        Assert-Audio ($script:gptNiangAudio.Faulted -and !$script:gptNiangAudio.PendingRelease -and $broken.Disposed) 'Driver error left a live partial pair'
        $script:gptNiangAudio.RetryClock.Reset();Play-WidgetPressSound;Play-WidgetReleaseSound
        $replacement=$script:gptNiangAudio.Engine;$replacement.PressCompleted=$true;Update-WidgetAudio
        Assert-Audio ($replacement.PressStarts-eq 1 -and $replacement.ReleaseStarts-eq 1) 'Driver error persisted across a fresh pair'
    }
    # A non-completing driver is cancelled, never interpreted as successful press playback.
    $hang=[WidgetAudioTestEngine]::new();$script:gptNiangAudio=New-TestAudio $hang
    Play-WidgetPressSound;Play-WidgetReleaseSound
    $clock=[pscustomobject]@{ElapsedMilliseconds=5001}
    $clock|Add-Member ScriptMethod Reset {}
    $script:gptNiangAudio.PlaybackClock=$clock;Update-WidgetAudio
    Assert-Audio ($hang.ReleaseStarts-eq 0 -and $script:gptNiangAudio.Faulted -and $hang.Disposed) 'Hung press was converted to release-only playback'
    Close-WidgetAudio
    $retired=[Collections.Generic.List[object]]::new()
    for($i=0;$i-lt 2;$i++){
        $retained=[WidgetAudioTestEngine]::new();$retained.FailDispose=$true;$retired.Add($retained)
        $script:gptNiangAudio=New-TestAudio $retained;Close-WidgetAudio
    }
    Assert-Audio ($script:widgetAudioRetired.Count-eq 2) 'Failed cleanup lost its native resource references across instances'
    $limited=$false
    try{& $realEngineFactory $appDir}catch{$limited=$_.Exception.Message.Contains('cleanup is still pending')}
    Assert-Audio $limited 'Failed cleanup could accumulate a third native output device'
    foreach($retained in $retired){$retained.FailDispose=$false}
    Complete-WidgetAudioCleanup
    Assert-Audio ($script:widgetAudioRetired.Count-eq 0) 'Retired resource cleanup could not be retried'
    Write-Output 'PASS: delayed completion, old tick/instance isolation, one release, long hold, capture loss, mute/zero/fractional volume, persistent press failure, release/reset failures, throttled whole-pair recovery, hung driver cancellation and retained bounded cleanup retries'
}finally{Close-WidgetAudio}
