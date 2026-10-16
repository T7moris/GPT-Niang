# Continuous PCM output: exact silence between original click sounds.
# Driver completion gates press/release; the WPF thread never feeds the stream.
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
function Initialize-WidgetContinuousType {
    if ('GptNiangContinuousAudio' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

// Keep one shared output stream supplied, including exact-zero PCM between
// clicks. Emptying the queue between tiny sounds can make wireless devices pop.
public sealed class GptNiangContinuousAudio : IDisposable {
    [StructLayout(LayoutKind.Sequential,Pack=2)]
    struct WaveFormat {
        public ushort Tag,Channels;
        public uint SamplesPerSecond,BytesPerSecond;
        public ushort BlockAlign,BitsPerSample,Extra;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct WaveHeader {
        public IntPtr Data;
        public uint Length,BytesRecorded;
        public UIntPtr User;
        public uint Flags,Loops;
        public IntPtr Next;
        public UIntPtr Reserved;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct WaveTime { public uint Type,Value,Reserved; }
    sealed class Clip {
        public WaveFormat Format;
        public byte[] Samples,LastSamples;
    }
    sealed class Buffer {
        public byte[] Samples;
        public IntPtr Data,Header;
        public bool Prepared;
        public int EndKind;
        public long Generation;
    }
    [DllImport("winmm.dll")] static extern uint waveOutOpen(out IntPtr device,uint id,ref WaveFormat format,IntPtr callback,IntPtr instance,uint flags);
    [DllImport("winmm.dll")] static extern uint waveOutPrepareHeader(IntPtr device,IntPtr header,uint size);
    [DllImport("winmm.dll")] static extern uint waveOutUnprepareHeader(IntPtr device,IntPtr header,uint size);
    [DllImport("winmm.dll")] static extern uint waveOutWrite(IntPtr device,IntPtr header,uint size);
    [DllImport("winmm.dll")] static extern uint waveOutReset(IntPtr device);
    [DllImport("winmm.dll")] static extern uint waveOutClose(IntPtr device);
    [DllImport("winmm.dll")] static extern uint waveOutPause(IntPtr device);
    [DllImport("winmm.dll")] static extern uint waveOutRestart(IntPtr device);
    [DllImport("winmm.dll")] static extern uint waveOutGetPosition(IntPtr device,ref WaveTime time,uint size);
    static readonly uint HeaderSize=(uint)Marshal.SizeOf(typeof(WaveHeader));
    const uint InQueue=16,Prepared=2,CallbackEvent=0x50000;
    readonly object gate=new object();
    readonly AutoResetEvent signal=new AutoResetEvent(false);
    readonly Clip press,release;
    readonly Buffer[] buffers=new Buffer[4];
    readonly System.Diagnostics.Stopwatch driverProgress=new System.Diagnostics.Stopwatch();
    WaveFormat format;
    IntPtr device;
    Thread worker;
    Exception failure;
    byte[] current,fade;
    int offset,currentKind,nextBuffer,fadeOffset;
    uint submittedFrames,requestFrame;
    bool hasRequestPosition;
    double lastPressQueueDelayMs=Double.NaN;
    long generation;
    bool busy,pressDone,releaseStarted,stopping,disposed;
    public bool IsMuted { get; set; }
    public double PressDuration { get; private set; }
    // Software queue delay only; driver/mixer/wireless latency is additional.
    public double LastPressQueueDelayMs { get { lock(gate) { return lastPressQueueDelayMs; } } }
    public bool PressCompleted { get { lock(gate) { CheckAlive();return pressDone; } } }
    public bool PlaybackCompleted { get { lock(gate) { CheckAlive();return !busy; } } }

    static void Check(uint code,string operation) {
        if(code!=0) throw new InvalidOperationException(operation+" failed (MMRESULT "+code+").");
    }
    void CheckAlive() {
        if(disposed || stopping || device==IntPtr.Zero) throw new ObjectDisposedException("Click audio");
        if(failure!=null) throw new InvalidOperationException("Click output failed.",failure);
        if(driverProgress.ElapsedMilliseconds>5000) throw new InvalidOperationException("Click output driver stopped completing buffers.");
    }
    static Clip ReadClip(string path) {
        using(var r=new BinaryReader(File.OpenRead(path))) {
            if(r.ReadUInt32()!=0x46464952) throw new InvalidDataException("Invalid RIFF sound.");
            r.ReadUInt32();
            if(r.ReadUInt32()!=0x45564157) throw new InvalidDataException("Invalid WAVE sound.");
            WaveFormat f=new WaveFormat();byte[] samples=null;
            while(r.BaseStream.Position+8<=r.BaseStream.Length) {
                uint kind=r.ReadUInt32(),length=r.ReadUInt32();
                long next=r.BaseStream.Position+length+(length&1);
                if(length>int.MaxValue || next>r.BaseStream.Length) throw new InvalidDataException("Invalid sound chunk.");
                if(kind==0x20746D66) {
                    if(length<16) throw new InvalidDataException("Invalid PCM format.");
                    f.Tag=r.ReadUInt16();f.Channels=r.ReadUInt16();f.SamplesPerSecond=r.ReadUInt32();
                    f.BytesPerSecond=r.ReadUInt32();f.BlockAlign=r.ReadUInt16();f.BitsPerSample=r.ReadUInt16();
                } else if(kind==0x61746164) samples=r.ReadBytes((int)length);
                r.BaseStream.Position=next;
            }
            if(f.Tag!=1 || f.BitsPerSample!=16 || f.Channels<1 || f.Channels>2 ||
               f.SamplesPerSecond==0 || f.BlockAlign!=f.Channels*2 ||
               f.BytesPerSecond!=(ulong)f.SamplesPerSecond*f.BlockAlign ||
               samples==null || samples.Length==0 || samples.Length%f.BlockAlign!=0)
                throw new InvalidDataException("Click sounds must be complete 16-bit PCM WAVs.");
            return new Clip {Format=f,Samples=samples};
        }
    }
    public GptNiangContinuousAudio(string pressPath,string releasePath) {
        press=ReadClip(pressPath);release=ReadClip(releasePath);format=press.Format;
        if(format.Channels!=release.Format.Channels || format.SamplesPerSecond!=release.Format.SamplesPerSecond)
            throw new InvalidDataException("Click sounds must use the same PCM format.");
        PressDuration=(double)press.Samples.Length/format.BytesPerSecond;
        int length=checked((int)((format.SamplesPerSecond+99)/100)*format.BlockAlign);
        for(int i=0;i<buffers.Length;i++) buffers[i]=new Buffer {Samples=new byte[length]};
    }
    static WaveHeader ReadHeader(Buffer b) { return (WaveHeader)Marshal.PtrToStructure(b.Header,typeof(WaveHeader)); }
    void Prepare(Buffer b) {
        b.Data=Marshal.AllocHGlobal(b.Samples.Length);b.Header=Marshal.AllocHGlobal((int)HeaderSize);
        Marshal.StructureToPtr(new WaveHeader {Data=b.Data,Length=(uint)b.Samples.Length},b.Header,false);
        Check(waveOutPrepareHeader(device,b.Header,HeaderSize),"Prepare output buffer");b.Prepared=true;
    }
    void Submit(Buffer b) {
        var h=ReadHeader(b);
        if((h.Flags&InQueue)!=0) throw new InvalidOperationException("Output buffer is still playing.");
        Array.Clear(b.Samples,0,b.Samples.Length);b.EndKind=0;b.Generation=generation;
        if(current!=null) {
            if(currentKind==1 && offset==0 && hasRequestPosition)
                lastPressQueueDelayMs=unchecked(submittedFrames-requestFrame)*1000.0/format.SamplesPerSecond;
            int count=Math.Min(b.Samples.Length,current.Length-offset);
            Array.Copy(current,offset,b.Samples,0,count);offset+=count;
            if(offset==current.Length) { b.EndKind=currentKind;current=null;offset=0; }
        }
        if(fade!=null) {
            int count=Math.Min(b.Samples.Length,fade.Length-fadeOffset);
            for(int i=0;i<count;i+=2) {
                int sample=Sample(b.Samples,i)+Sample(fade,fadeOffset+i);
                short mixed=(short)Math.Max(Int16.MinValue,Math.Min(Int16.MaxValue,sample));
                b.Samples[i]=(byte)(mixed&255);b.Samples[i+1]=(byte)((mixed>>8)&255);
            }
            fadeOffset+=count;if(fadeOffset==fade.Length) { fade=null;fadeOffset=0; }
        }
        Marshal.Copy(b.Samples,0,b.Data,b.Samples.Length);
        h.Flags&=Prepared;Marshal.StructureToPtr(h,b.Header,false);
        Check(waveOutWrite(device,b.Header,HeaderSize),"Submit continuous output");
        submittedFrames=unchecked(submittedFrames+(uint)(b.Samples.Length/format.BlockAlign));
    }
    public void Open() {
        lock(gate) {
            if(disposed || device!=IntPtr.Zero) throw new InvalidOperationException("Click audio is already opened or disposed.");
            Check(waveOutOpen(out device,UInt32.MaxValue,ref format,signal.SafeWaitHandle.DangerousGetHandle(),IntPtr.Zero,CallbackEvent),"Open click audio");
            Check(waveOutPause(device),"Prime click output");
            foreach(var b in buffers) Prepare(b);
            foreach(var b in buffers) Submit(b);
            worker=new Thread(Run);worker.IsBackground=true;worker.Name="GPT Niang audio output";worker.Start();
            driverProgress.Restart();Check(waveOutRestart(device),"Start primed click output");
        }
    }
    void Run() {
        try {
            while(true) {
                signal.WaitOne(100);
                lock(gate) {
                    if(stopping) return;
                    // Refill in queue order even when several completions arrive
                    // together. Work is independent of WPF rendering/IO delays.
                    for(int n=0;n<buffers.Length;n++) {
                        Buffer b=buffers[nextBuffer];
                        if((ReadHeader(b).Flags&InQueue)!=0) break;
                        driverProgress.Restart();
                        if(b.Generation==generation) {
                            if(b.EndKind==1) pressDone=true;
                            if(b.EndKind==2) busy=false;
                        }
                        Submit(b);nextBuffer=(nextBuffer+1)%buffers.Length;
                    }
                }
            }
        } catch(Exception ex) { lock(gate) { failure=ex; } }
    }
    static int Sample(byte[] bytes,int at) {
        return bytes!=null && at+1<bytes.Length ? (short)(bytes[at] | (bytes[at+1]<<8)) : 0;
    }
    void FadePrevious() {
        if(current==null && fade==null) return;
        int frames=Math.Max(2,(int)(format.SamplesPerSecond/100));
        var tail=new byte[frames*format.BlockAlign];
        for(int frame=0;frame<frames;frame++) {
            double gain=(frames-1-frame)/(double)(frames-1);
            for(int channel=0;channel<format.Channels;channel++) {
                int at=frame*format.BlockAlign+channel*2;
                int source=Sample(current,offset+at)+Sample(fade,fadeOffset+at);
                short sample=(short)Math.Max(Int16.MinValue,Math.Min(Int16.MaxValue,Math.Round(source*gain)));
                tail[at]=(byte)(sample&255);tail[at+1]=(byte)((sample>>8)&255);
            }
        }
        fade=tail;fadeOffset=0;
    }
    void Start(Clip clip,double volume,int kind) {
        if(double.IsNaN(volume) || double.IsInfinity(volume)) throw new ArgumentOutOfRangeException("volume");
        volume=IsMuted?0:Math.Max(0,Math.Min(1,volume));
        byte[] samples=new byte[clip.Samples.Length];
        for(int i=0;i<samples.Length;i+=2) {
            short original=(short)(clip.Samples[i] | (clip.Samples[i+1]<<8));
            short scaled=(short)Math.Round(original*volume,MidpointRounding.AwayFromZero);
            samples[i]=(byte)(scaled&255);samples[i+1]=(byte)((scaled>>8)&255);
        }
        clip.LastSamples=samples;current=samples;offset=0;currentKind=kind;busy=true;
    }
    public void StartPress(double volume) {
        lock(gate) {
            CheckAlive();FadePrevious();
            WaveTime time=new WaveTime {Type=2};
            hasRequestPosition=waveOutGetPosition(device,ref time,12)==0 && time.Type==2;
            requestFrame=time.Value;
            generation++;pressDone=false;releaseStarted=false;Start(press,volume,1);
        }
    }
    public void StartRelease(double volume) {
        lock(gate) {
            CheckAlive();if(!pressDone || current!=null || releaseStarted) throw new InvalidOperationException("Press audio is incomplete or release was already submitted.");
            Start(release,volume,2);releaseStarted=true;
        }
    }
    public void Stop() {
        lock(gate) {
            CheckAlive();
            // Explicit mute/capture loss/shutdown can cancel; normal clicks
            // never reset the stream or replace queued nonzero PCM.
            Check(waveOutReset(device),"Reset click audio");
            generation++;current=null;fade=null;offset=0;fadeOffset=0;busy=false;pressDone=false;releaseStarted=false;
            submittedFrames=0;hasRequestPosition=false;driverProgress.Restart();
            foreach(var b in buffers) { b.EndKind=0;b.Generation=generation; }
            nextBuffer=0;signal.Set();
        }
    }
    public void Dispose() {
        Thread previous;
        lock(gate) { if(disposed) return;stopping=true;previous=worker;signal.Set(); }
        if(previous!=null && previous.IsAlive && !previous.Join(1000))
            throw new InvalidOperationException("Click audio cleanup is still pending.");
        lock(gate) {
            if(device!=IntPtr.Zero) {
                Check(waveOutReset(device),"Reset output for cleanup");
                foreach(var b in buffers) {
                    if(b.Prepared) { Check(waveOutUnprepareHeader(device,b.Header,HeaderSize),"Unprepare output buffer");b.Prepared=false; }
                }
                Check(waveOutClose(device),"Close click audio");device=IntPtr.Zero;
            }
            foreach(var b in buffers) {
                if(b.Header!=IntPtr.Zero) { Marshal.FreeHGlobal(b.Header);b.Header=IntPtr.Zero; }
                if(b.Data!=IntPtr.Zero) { Marshal.FreeHGlobal(b.Data);b.Data=IntPtr.Zero; }
            }
            signal.Dispose();disposed=true;worker=null;
        }
    }
}

'@
}
function New-WidgetAudioEngine([string]$AppDir) {
    Initialize-WidgetContinuousType
    Complete-WidgetAudioCleanup
    if ($script:widgetAudioRetired.Count -ge 2) { throw 'Click audio cleanup is still pending.' }
    $engine=[GptNiangContinuousAudio]::new([IO.Path]::GetFullPath((Join-Path $AppDir 'assets/press.wav')),[IO.Path]::GetFullPath((Join-Path $AppDir 'assets/release.wav')))
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
    # Turning sound off/zero must also release the otherwise continuous stream.
    if (-not (Get-WidgetAudioEnabled) -or (Get-WidgetAudioVolume) -le 0) {
        Remove-WidgetAudioEngine $audio.Engine;$audio.Engine=$null;$audio.Faulted=$true
        $audio.RetryClock.Reset()
    }
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
    if (-not (Get-WidgetAudioEnabled) -or (Get-WidgetAudioVolume) -le 0) { return }
    try { $script:gptNiangAudio.Engine=New-WidgetAudioEngine $AppDir;$script:gptNiangAudio.Faulted=$false }
    catch { $script:gptNiangAudio.RetryClock.Restart() }
}
function Play-WidgetPressSound {
    $audio=$script:gptNiangAudio
    if ($null -eq $audio) { return }
    if (-not (Get-WidgetAudioEnabled) -or (Get-WidgetAudioVolume) -le 0) { Stop-WidgetAudio;return }
    # Every press retriggers immediately; the audio worker crossfades the old
    # tail into the new onset. No WPF-side duration wait or growing sound queue.
    if (-not $audio.Faulted -and $audio.Engine -and $audio.PlaybackClock.ElapsedMilliseconds -gt 5000) {
        try { if (-not $audio.Engine.PlaybackCompleted) { Disable-WidgetAudioPair $audio } }
        catch { Disable-WidgetAudioPair $audio }
    }
    if ($audio.Faulted) {
        if ($audio.RetryClock.IsRunning -and $audio.RetryClock.ElapsedMilliseconds -lt 1000) { return }
        try { $audio.Engine=New-WidgetAudioEngine $audio.AppDir;$audio.Faulted=$false }
        catch { $audio.RetryClock.Restart();return }
    }
    try {
        $audio.Timer.Stop();$audio.PendingRelease=$false;$audio.ReleasePlayed=$true
        $audio.Pressing=$false;$audio.PressEnded=$true;$audio.PlaybackClock.Reset()
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
