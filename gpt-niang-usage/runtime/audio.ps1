# Preloaded PCM click sounds. Dot-source on the WPF STA thread.
# Playback completion comes from the driver, never from time since the mouse click.
if ($null -eq (Get-Variable -Name gptNiangAudio -Scope Script -ErrorAction SilentlyContinue)) {
    $script:gptNiangAudio = $null
}
if ($null -eq (Get-Variable -Name widgetAudioRetired -Scope Script -ErrorAction SilentlyContinue)) {
    $script:widgetAudioRetired = [Collections.Generic.List[object]]::new()
}
function Get-WidgetAudioEnabled {
    $setting = Get-Variable -Name soundOn -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $setting) { return $true }
    return ($setting.Value -ne $false)
}
function Get-WidgetAudioVolume {
    $setting = Get-Variable -Name soundVolume -Scope Script -ErrorAction SilentlyContinue
    $value = 0.9
    if ($null -ne $setting) { try { $value = [double]$setting.Value } catch { $value = 0.9 } }
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { $value = 0.9 }
    return [Math]::Min(1.0, [Math]::Max(0.0, $value))
}
function Initialize-WidgetPcmType {
    if ('GptNiangPcmAudio' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;

public sealed class GptNiangPcmAudio : IDisposable {
    [StructLayout(LayoutKind.Sequential, Pack=2)]
    struct WaveFormat {
        public ushort Tag, Channels;
        public uint SamplesPerSecond, BytesPerSecond;
        public ushort BlockAlign, BitsPerSample, Extra;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct WaveHeader {
        public IntPtr Data;
        public uint Length, BytesRecorded;
        public UIntPtr User;
        public uint Flags, Loops;
        public IntPtr Next;
        public UIntPtr Reserved;
    }
    sealed class Clip {
        public WaveFormat Format;
        public byte[] Samples;
    }
    sealed class Buffer {
        public byte[] Source, Scaled;
        public IntPtr Data, Header;
        public bool Prepared;
    }
    [DllImport("winmm.dll")] static extern uint waveOutOpen(out IntPtr device, uint id, ref WaveFormat format, IntPtr callback, IntPtr instance, uint flags);
    [DllImport("winmm.dll")] static extern uint waveOutPrepareHeader(IntPtr device, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint waveOutUnprepareHeader(IntPtr device, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint waveOutWrite(IntPtr device, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint waveOutReset(IntPtr device);
    [DllImport("winmm.dll")] static extern uint waveOutClose(IntPtr device);
    static readonly uint HeaderSize = (uint)Marshal.SizeOf(typeof(WaveHeader));
    const uint Done = 1, Prepared = 2, InQueue = 16;
    IntPtr device;
    Buffer press, release;
    WaveFormat format;
    bool disposed, cleanupComplete, pressQueued;
    public bool IsMuted { get; set; }
    public double PressDuration { get; private set; }
    public bool PressCompleted {
        get { CheckAlive(); return pressQueued && (ReadHeader(press).Flags & Done) != 0; }
    }
    static void Check(uint result, string operation) {
        if (result != 0) throw new InvalidOperationException(operation + " failed (MMRESULT " + result + ").");
    }
    static Clip ReadClip(string path) {
        using (var reader = new BinaryReader(File.OpenRead(path))) {
            if (reader.ReadUInt32() != 0x46464952) throw new InvalidDataException("Invalid RIFF sound.");
            reader.ReadUInt32();
            if (reader.ReadUInt32() != 0x45564157) throw new InvalidDataException("Invalid WAVE sound.");
            WaveFormat format = new WaveFormat(); byte[] samples = null;
            while (reader.BaseStream.Position + 8 <= reader.BaseStream.Length) {
                uint kind = reader.ReadUInt32(), length = reader.ReadUInt32();
                long next = reader.BaseStream.Position + length + (length & 1);
                if (length > int.MaxValue || next > reader.BaseStream.Length) throw new InvalidDataException("Invalid sound chunk.");
                if (kind == 0x20746D66) {
                    if (length < 16) throw new InvalidDataException("Invalid PCM format.");
                    format.Tag=reader.ReadUInt16(); format.Channels=reader.ReadUInt16();
                    format.SamplesPerSecond=reader.ReadUInt32(); format.BytesPerSecond=reader.ReadUInt32();
                    format.BlockAlign=reader.ReadUInt16(); format.BitsPerSample=reader.ReadUInt16();
                } else if (kind == 0x61746164) { samples=reader.ReadBytes((int)length); }
                reader.BaseStream.Position=next;
            }
            if (format.Tag!=1 || format.BitsPerSample!=16 || format.Channels<1 || format.Channels>2 ||
                format.SamplesPerSecond==0 || format.BlockAlign!=format.Channels*2 ||
                format.BytesPerSecond!=(ulong)format.SamplesPerSecond*format.BlockAlign ||
                samples==null || samples.Length==0 || samples.Length%format.BlockAlign!=0) {
                throw new InvalidDataException("Click sounds must be complete 16-bit PCM WAVs.");
            }
            return new Clip { Format=format, Samples=samples };
        }
    }
    void Prepare(Buffer buffer) {
        try {
            buffer.Data=Marshal.AllocHGlobal(buffer.Source.Length);
            buffer.Header=Marshal.AllocHGlobal((int)HeaderSize);
            Marshal.StructureToPtr(new WaveHeader { Data=buffer.Data, Length=(uint)buffer.Source.Length },buffer.Header,false);
            Check(waveOutPrepareHeader(device,buffer.Header,HeaderSize),"Prepare click buffer");
            buffer.Prepared=true;
        } catch { Free(buffer); throw; }
    }
    static WaveHeader ReadHeader(Buffer buffer) { return (WaveHeader)Marshal.PtrToStructure(buffer.Header,typeof(WaveHeader)); }
    static void Free(Buffer buffer) {
        if(buffer==null) return;
        if(buffer.Header!=IntPtr.Zero) { Marshal.FreeHGlobal(buffer.Header); buffer.Header=IntPtr.Zero; }
        if(buffer.Data!=IntPtr.Zero) { Marshal.FreeHGlobal(buffer.Data); buffer.Data=IntPtr.Zero; }
    }
    void CheckAlive() { if(disposed || device==IntPtr.Zero) throw new ObjectDisposedException("Click audio"); }
    public GptNiangPcmAudio(string pressPath,string releasePath) {
        Clip down=ReadClip(pressPath), up=ReadClip(releasePath);
        if(down.Format.Channels!=up.Format.Channels || down.Format.SamplesPerSecond!=up.Format.SamplesPerSecond)
            throw new InvalidDataException("Click sounds must use the same PCM format.");
        PressDuration=(double)down.Samples.Length/down.Format.BytesPerSecond;
        format=down.Format;
        press=new Buffer { Source=down.Samples, Scaled=new byte[down.Samples.Length] };
        release=new Buffer { Source=up.Samples, Scaled=new byte[up.Samples.Length] };
    }
    public void Open() {
        if(disposed || device!=IntPtr.Zero) throw new InvalidOperationException("Click audio is already opened or disposed.");
        Check(waveOutOpen(out device,UInt32.MaxValue,ref format,IntPtr.Zero,IntPtr.Zero,0),"Open click audio");
        // Keep this instance reachable even if preparing the second buffer fails.
        Prepare(press);Prepare(release);
    }
    void Queue(Buffer buffer,double volume) {
        CheckAlive(); var header=ReadHeader(buffer);
        if((header.Flags & InQueue)!=0) throw new InvalidOperationException("Click buffer is still playing.");
        volume=IsMuted ? 0 : Math.Max(0,Math.Min(1,volume));
        // Scale only returned PCM memory, keeping the system/application mixer untouched.
        for(int i=0;i<buffer.Source.Length;i+=2) {
            short original=(short)(buffer.Source[i] | (buffer.Source[i+1]<<8));
            short scaled=(short)Math.Round(original*volume);
            buffer.Scaled[i]=(byte)(scaled & 255); buffer.Scaled[i+1]=(byte)((scaled>>8) & 255);
        }
        Marshal.Copy(buffer.Scaled,0,buffer.Data,buffer.Scaled.Length);
        header.Flags &= Prepared; Marshal.StructureToPtr(header,buffer.Header,false);
        Check(waveOutWrite(device,buffer.Header,HeaderSize),"Submit complete click buffer");
    }
    public void Stop() {
        CheckAlive(); Check(waveOutReset(device),"Reset click audio");
        if((ReadHeader(press).Flags & InQueue)!=0 || (ReadHeader(release).Flags & InQueue)!=0)
            throw new InvalidOperationException("Driver did not return the cancelled click buffers.");
        pressQueued=false;
    }
    public void StartPress(double volume) { Stop(); Queue(press,volume); pressQueued=true; }
    public void StartRelease(double volume) {
        if(!PressCompleted) throw new InvalidOperationException("Press audio has not completed.");
        Queue(release,volume);
    }
    void Unprepare(Buffer buffer) {
        if(buffer==null) return;
        if(buffer.Prepared) Check(waveOutUnprepareHeader(device,buffer.Header,HeaderSize),"Unprepare click buffer");
        buffer.Prepared=false; Free(buffer);
    }
    public void Dispose() {
        if(cleanupComplete) return; disposed=true;
        if(device==IntPtr.Zero) { cleanupComplete=true; return; }
        // A faulty driver must never receive freed or overwritten queued memory.
        Check(waveOutReset(device),"Reset click audio for cleanup");
        Unprepare(press);Unprepare(release);
        Check(waveOutClose(device),"Close click audio");
        device=IntPtr.Zero;cleanupComplete=true;
    }
}
'@
}
function New-WidgetAudioEngine([string]$AppDir) {
    Initialize-WidgetPcmType
    Complete-WidgetAudioCleanup
    if ($script:widgetAudioRetired.Count -ge 2) { throw 'Click audio cleanup is still pending.' }
    $engine=[GptNiangPcmAudio]::new([IO.Path]::GetFullPath((Join-Path $AppDir 'assets/press.wav')),[IO.Path]::GetFullPath((Join-Path $AppDir 'assets/release.wav')))
    try { $engine.Open();return $engine }
    catch { Remove-WidgetAudioEngine $engine;throw }
}
function Complete-WidgetAudioCleanup {
    foreach ($engine in @($script:widgetAudioRetired.ToArray())) {
        try { $engine.Dispose();$null=$script:widgetAudioRetired.Remove($engine) } catch {}
    }
}
function Remove-WidgetAudioEngine($Engine) {
    if ($null -eq $Engine) { return }
    try { $Engine.Dispose() }
    catch { if (-not $script:widgetAudioRetired.Contains($Engine)) { $script:widgetAudioRetired.Add($Engine) } }
}
function Set-WidgetAudioVolume {
    param([double]$Volume = -1)
    if ($Volume -ge 0 -and -not [double]::IsNaN($Volume) -and -not [double]::IsInfinity($Volume)) {
        $script:soundVolume = [Math]::Min(1.0, [Math]::Max(0.0, $Volume))
    }
    if ((Get-WidgetAudioVolume) -le 0) { Stop-WidgetAudio }
}
function Disable-WidgetAudioPair($Audio) {
    $Audio.Timer.Stop();$Audio.Pressing=$false;$Audio.PressEnded=$true
    $Audio.PendingRelease=$false;$Audio.ReleasePlayed=$true;$Audio.Faulted=$true
    try { $Audio.Engine.Stop() } catch {}
    Remove-WidgetAudioEngine $Audio.Engine
    $Audio.Engine=$null;$Audio.PlaybackClock.Reset();$Audio.RetryClock.Restart()
}
function Invoke-WidgetReleaseNow {
    $audio = $script:gptNiangAudio
    if ($null -eq $audio -or $audio.Faulted -or -not $audio.PendingRelease -or $audio.Pressing -or $audio.ReleasePlayed) { return }
    if (-not (Get-WidgetAudioEnabled) -or (Get-WidgetAudioVolume) -le 0) { Stop-WidgetAudio;return }
    try {
        if (-not $audio.Engine.PressCompleted) { return }
        $audio.Engine.StartRelease((Get-WidgetAudioVolume))
        $audio.Timer.Stop();$audio.PendingRelease=$false;$audio.ReleasePlayed=$true
    } catch { Disable-WidgetAudioPair $audio }
}
function Update-WidgetAudio($Audio=$script:gptNiangAudio) {
    if ($null -eq $Audio -or -not [object]::ReferenceEquals($Audio,$script:gptNiangAudio) -or $Audio.Faulted) { return }
    try {
        if (-not $Audio.Engine.PressCompleted) {
            # A hung/removed driver cancels this whole pair; elapsed time never starts release.
            if ($Audio.PlaybackClock.ElapsedMilliseconds -gt 5000) { Disable-WidgetAudioPair $Audio }
            return
        }
        $Audio.PressEnded=$true
        if ($Audio.PendingRelease -and -not $Audio.Pressing) { Invoke-WidgetReleaseNow }
        else { $Audio.Timer.Stop() }
    } catch { Disable-WidgetAudioPair $Audio }
}
function Stop-WidgetAudio {
    $audio=$script:gptNiangAudio
    if ($null -eq $audio) { return }
    $audio.Timer.Stop();$audio.PendingRelease=$false;$audio.ReleasePlayed=$true
    $audio.Pressing=$false;$audio.PressEnded=$true;$audio.PlaybackClock.Reset()
    if ($audio.Engine) { try { $audio.Engine.Stop() } catch { Disable-WidgetAudioPair $audio } }
}
function Close-WidgetAudio {
    $audio=$script:gptNiangAudio
    if ($null -eq $audio) { return }
    Stop-WidgetAudio
    if ($audio.Engine) { Remove-WidgetAudioEngine $audio.Engine }
    $script:gptNiangAudio=$null
    Complete-WidgetAudioCleanup
}
function Initialize-WidgetAudio {
    param([Parameter(Mandatory=$true)][string]$AppDir)
    Close-WidgetAudio
    Add-Type -AssemblyName WindowsBase
    $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(8)
    $script:gptNiangAudio=@{AppDir=$AppDir;Engine=$null;Timer=$timer;Pressing=$false;PressEnded=$true;PendingRelease=$false;ReleasePlayed=$true;Faulted=$true;RetryClock=[Diagnostics.Stopwatch]::new();PlaybackClock=[Diagnostics.Stopwatch]::new()}
    $timer.Add_Tick({param($sender,$eventArgs)
        $audio=$script:gptNiangAudio
        if ($audio -and [object]::ReferenceEquals($sender,$audio.Timer)) { Update-WidgetAudio $audio }
    })
    try { $script:gptNiangAudio.Engine=New-WidgetAudioEngine $AppDir;$script:gptNiangAudio.Faulted=$false }
    catch { $script:gptNiangAudio.RetryClock.Restart() }
}
function Play-WidgetPressSound {
    $audio=$script:gptNiangAudio
    if ($null -eq $audio) { return }
    Stop-WidgetAudio
    if (-not (Get-WidgetAudioEnabled) -or (Get-WidgetAudioVolume) -le 0) { return }
    if ($audio.Faulted) {
        if ($audio.RetryClock.IsRunning -and $audio.RetryClock.ElapsedMilliseconds -lt 1000) { return }
        try { $audio.Engine=New-WidgetAudioEngine $audio.AppDir;$audio.Faulted=$false }
        catch { $audio.RetryClock.Restart();return }
    }
    try {
        $audio.Engine.StartPress((Get-WidgetAudioVolume))
        $audio.Pressing=$true;$audio.PressEnded=$false;$audio.ReleasePlayed=$false
        $audio.PlaybackClock.Restart()
        $audio.Timer.Start()
    } catch { Disable-WidgetAudioPair $audio }
}
function Play-WidgetReleaseSound {
    $audio=$script:gptNiangAudio
    if ($null -eq $audio -or -not $audio.Pressing -or $audio.Faulted) { return }
    $audio.Pressing=$false
    if (-not (Get-WidgetAudioEnabled) -or (Get-WidgetAudioVolume) -le 0) { Stop-WidgetAudio;return }
    $audio.PendingRelease=$true;Update-WidgetAudio $audio
}
