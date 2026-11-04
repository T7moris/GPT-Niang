using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

// Shared-mode render loopback only. Samples stay on this worker and are never
// retained, written to disk, sent over IPC, or passed to the WPF dispatcher.
public sealed class GptMusicCapture : IDisposable {
    readonly object gate = new object();
    readonly ManualResetEvent stop = new ManualResetEvent(false);
    readonly Thread worker;
    GptMusicAudioSnapshot state = new GptMusicAudioSnapshot();
    int disposed;readonly bool autoMusic;readonly uint explicitProcess;readonly GptMusicPlaybackSource source=new GptMusicPlaybackSource();uint selectedProcess;bool processUnsupported;
    readonly double startedAt=NowMs;long selectedCreation;bool fallbackPending;
    public static double NowMs { get { return Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency; } }
    public GptMusicCapture():this(false,0){}
    public GptMusicCapture(bool preferMusic):this(preferMusic,0){}
    public GptMusicCapture(uint processId):this(false,processId){}
    GptMusicCapture(bool preferMusic,uint processId) {
        autoMusic=preferMusic;explicitProcess=processId;
        worker = new Thread(Run) { IsBackground = true, Name = "GPT Niang playback rhythm" };
        worker.SetApartmentState(ApartmentState.MTA); worker.Start();
    }
    public GptMusicAudioSnapshot Snapshot() {
        lock (gate) {
            var s = (GptMusicAudioSnapshot)state.Clone();
            double stale=NowMs-s.PacketAtMs;
            if(stale>150){s.Level=s.LowLevel=s.Drive=0;}
            if(stale>Math.Max(300,s.PeriodMs*1.6)){s.RhythmLocked=false;s.Confidence=0;}
            return s;
        }
    }
    void Run() {
        int failures = 0;
        try {
            while (!stop.WaitOne(0)) {
                try { Capture(); failures = 0; }
                catch (Exception e) {
                    if(fallbackPending){fallbackPending=false;continue;}
                    lock (gate) { state.Running = false; state.RhythmLocked=false; state.Error = e.GetType().Name + ": " + e.Message; state.Level = state.LowLevel = state.Drive = 0; }
                    failures = Math.Min(3, failures + 1);
                }
                if (stop.WaitOne(failures == 0 ? 50 : Math.Min(4000, 500 * (1 << failures)))) break;
            }
        } finally {
            lock (gate) { state.Running = false; state.Level = state.LowLevel = state.Drive = 0; }
            stop.Dispose();
        }
    }
    static void Check(int result) { if (result < 0) Marshal.ThrowExceptionForHR(result); }
    static void Release(object value) { if (value != null && Marshal.IsComObject(value)) Marshal.FinalReleaseComObject(value); }
    static bool ProcessMatches(uint pid,long creation){
        try{using(var process=Process.GetProcessById((int)pid))return process.StartTime.ToUniversalTime().Ticks==creation;}
        catch(ArgumentException){return false;}catch(InvalidOperationException){return false;}
    }
    uint ChooseProcess(){
        if(explicitProcess!=0)return explicitProcess;if(!autoMusic||processUnsupported||Environment.OSVersion.Version.Build<20348)return 0;
        uint candidate=source.Find();if(candidate!=0){selectedProcess=candidate;using(var process=Process.GetProcessById((int)candidate))selectedCreation=process.StartTime.ToUniversalTime().Ticks;}
        else if(selectedProcess!=0&&!ProcessMatches(selectedProcess,selectedCreation))selectedProcess=0;
        return selectedProcess;
    }
    void Capture() {
        uint target=ChooseProcess();
        if(autoMusic&&target!=0&&!ProcessMatches(target,selectedCreation)){
            selectedProcess=0;lock(gate){state.Running=state.RhythmLocked=false;state.Level=state.LowLevel=state.Drive=0;state.Error=null;}stop.WaitOne(250);return;
        }
        MusicDeviceEnumerator enumerator = null; IMusicDevice device = null;
        IMusicAudioClient client = null; IMusicCaptureClient capture = null;
        IntPtr format = IntPtr.Zero; bool started = false;string deviceId=null;Guid iid;
        try {
            if(target==0){
            enumerator = (MusicDeviceEnumerator)new MusicDeviceEnumeratorClass();
            Check(enumerator.GetDefaultAudioEndpoint(0, 1, out device)); // eRender, eMultimedia
            Check(device.GetId(out deviceId));
            iid = typeof(IMusicAudioClient).GUID; object activated;
            Check(device.Activate(ref iid, 23, IntPtr.Zero, out activated)); client = (IMusicAudioClient)activated;
            Check(client.GetMixFormat(out format));
            }else{
                try{client=(IMusicAudioClient)GptMusicProcessActivator.Open(target,stop);if(client==null)throw new InvalidOperationException("Music process capture returned no audio client.");format=GptMusicProcessActivator.Format();}
                catch(OperationCanceledException){throw;}
                catch{if(autoMusic){processUnsupported=true;selectedProcess=0;fallbackPending=true;}throw;}
            }
            var wave = (MusicWaveFormat)Marshal.PtrToStructure(format, typeof(MusicWaveFormat));
            int tag = wave.Tag;
            if (tag == 0xfffe) {
                if (wave.ExtraSize < 22) throw new NotSupportedException("Incomplete playback format.");
                Guid sub = (Guid)Marshal.PtrToStructure(IntPtr.Add(format, 24), typeof(Guid));
                if (sub == new Guid("00000003-0000-0010-8000-00aa00389b71")) tag = 3;
                else if (sub == new Guid("00000001-0000-0010-8000-00aa00389b71")) tag = 1;
                else throw new NotSupportedException("Unsupported playback encoding.");
            }
            int bytes = wave.Bits / 8;
            if (wave.Channels < 1 || wave.Channels > 32 || wave.Rate < 8000 || wave.Rate > 384000 ||
                wave.Align < wave.Channels * bytes || (tag != 1 && tag != 3) ||
                (tag == 3 ? wave.Bits != 32 : wave.Bits != 8 && wave.Bits != 16 && wave.Bits != 24 && wave.Bits != 32))
                throw new NotSupportedException("Unsupported playback sample format.");
            Check(client.Initialize(0, target==0?0x20000u:0x80020000u, 1000000, 0, format, IntPtr.Zero));
            iid = typeof(IMusicCaptureClient).GUID; object service;
            Check(client.GetService(ref iid, out service)); capture = (IMusicCaptureClient)service;
            var detector = new GptMusicBeatDetector((int)wave.Rate, wave.Channels);
            double[] values = new double[wave.Channels]; byte[] buffer = new byte[65536];
            long lastSequence = 0,lastBeats=0; double nextDeviceCheck = NowMs + 1000,nextSourceCheck=NowMs+100,previousPacket=NowMs;
            Check(client.Start()); started = true;
            lock (gate) { state.Running = true; state.RhythmLocked=false; state.Error = null; state.SampleRate = (int)wave.Rate; state.Channels = wave.Channels;state.Level=state.LowLevel=state.Drive=state.Strength=state.BeatAtMs=0;state.SourceProcessId=target;state.Source=target==0?"system-playback":"music-player";state.CaptureReadyMs=NowMs-startedAt; }
            while (!stop.WaitOne(5)) {
                uint packet; Check(capture.GetNextPacketSize(out packet));
                while (packet > 0 && !stop.WaitOne(0)) {
                    IntPtr data; uint frames, flags; ulong position, qpc;
                    Check(capture.GetBuffer(out data, out frames, out flags, out position, out qpc));
                    try {
                        int length = checked((int)frames * wave.Align);
                        if (length > 16 * 1024 * 1024) throw new NotSupportedException("Playback packet is too large.");
                        bool silent = (flags & 2) != 0;
                        double packetNow=NowMs;
                        if((flags&1)!=0){lock(gate){state.Discontinuities++;}}
                        if((flags&1)!=0||packetNow-previousPacket>1200)detector.Tempo.Reset();
                        previousPacket=packetNow;
                        if (!silent) { if (buffer.Length < length) buffer = new byte[length]; Marshal.Copy(data, buffer, 0, length); }
                        for (int f = 0; f < frames; f++) {
                            int offset = f * wave.Align;
                            for (int c = 0; c < values.Length; c++) values[c] = silent ? 0 : Decode(buffer, offset + c * bytes, tag, wave.Bits);
                            detector.Push(values);
                        }
                        lock (gate) {
                            state.PacketAtMs = NowMs;if(state.FirstPacketMs==0)state.FirstPacketMs=NowMs-startedAt; state.Level = detector.Level; state.LowLevel = detector.LowLevel; state.Drive = detector.Drive;
                            // WASAPI QPC describes the first audio frame, in 100 ns units.
                            // Processing completion is not the musical beat's timestamp.
                            double audioAt=qpc/10000.0+frames*1000.0/wave.Rate;
                            if((flags&4)!=0||audioAt>state.PacketAtMs+100||audioAt<state.PacketAtMs-1000)audioAt=state.PacketAtMs;
                            double offset=audioAt-detector.Time*1000;
                            var tempo=detector.Tempo;
                            state.Candidates=tempo.Candidates;state.TempoResets=tempo.Resets;state.EnvelopeScore=tempo.EnvelopeScore;state.EnvelopeBpm=tempo.EnvelopeBpm;
                            state.RhythmLocked=tempo.Locked;state.BassCycle=tempo.UsesBassCycle;state.Confidence=tempo.Confidence;state.Bpm=tempo.Bpm;state.PeriodMs=tempo.Period*1000;
                            state.NextBeatAtMs=offset+tempo.NextBeat*1000;state.AudioLagMs=state.PacketAtMs-audioAt;
                            state.BeatSequence+=tempo.Sequence-lastBeats;lastBeats=tempo.Sequence;
                            if (detector.Sequence != lastSequence) {
                                state.Sequence += detector.Sequence - lastSequence; state.BeatAtMs = state.PacketAtMs;
                                state.Strength = detector.Strength; lastSequence = detector.Sequence;
                            }
                        }
                    } finally { Check(capture.ReleaseBuffer(frames)); }
                    Check(capture.GetNextPacketSize(out packet));
                }
                if(autoMusic&&NowMs>=nextSourceCheck){nextSourceCheck=NowMs+(target==0?100:500);if(ChooseProcess()!=target)break;}
                if (NowMs >= nextDeviceCheck) {
                    nextDeviceCheck = NowMs + 1000;
                    if(target!=0)continue;
                    IMusicDevice current = null;
                    try {
                        Check(enumerator.GetDefaultAudioEndpoint(0, 1, out current)); string id; Check(current.GetId(out id));
                        if (!String.Equals(deviceId, id, StringComparison.Ordinal)) break;
                    } finally { Release(current); }
                }
            }
        } finally {
            if (started && client != null) try { client.Stop(); } catch { }
            Release(capture); Release(client); Release(device); Release(enumerator);
            if (format != IntPtr.Zero) Marshal.FreeCoTaskMem(format);
        }
    }
    public static double Decode(byte[] b, int at, int tag, int bits) {
        double v;
        if (tag == 3) v = BitConverter.ToSingle(b, at);
        else if (bits == 8) v = (b[at] - 128) / 128.0;
        else if (bits == 16) v = (short)(b[at] | b[at + 1] << 8) / 32768.0;
        else if (bits == 24) { int x = b[at] | b[at + 1] << 8 | b[at + 2] << 16; if ((x & 0x800000) != 0) x |= unchecked((int)0xff000000); v = x / 8388608.0; }
        else v = BitConverter.ToInt32(b, at) / 2147483648.0;
        return Double.IsNaN(v) || Double.IsInfinity(v) ? 0 : Math.Max(-1, Math.Min(1, v));
    }
    public void Dispose() {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        try { stop.Set(); } catch (ObjectDisposedException) { }
        if (Thread.CurrentThread != worker) worker.Join(250);
    }
}

public sealed class GptMusicAudioSnapshot : ICloneable {
    public uint SourceProcessId;public string Source="system-playback";public double CaptureReadyMs,FirstPacketMs;
    public bool Running,RhythmLocked,BassCycle; public string Error; public int SampleRate, Channels;
    public long Sequence; public double BeatAtMs, PacketAtMs, Strength, Level, LowLevel, Drive;
    public long BeatSequence;public double Confidence,Bpm,PeriodMs,NextBeatAtMs,AudioLagMs;
    public int Candidates,Discontinuities,TempoResets;
    public double EnvelopeScore,EnvelopeBpm;
    public object Clone() { return MemberwiseClone(); }
}

public sealed class GptMusicBeatDetector {
    readonly MusicBiquad[] high, low;
    readonly MusicBiquad[,] rhythmHigh,rhythmLow; readonly double[] rhythmEnergy=new double[4],rhythmPrevious=new double[4];
    readonly int channels, window;
    int count; double sum, broad, baseline, lastLow, peak, gainPeak, signalPeak, seconds, lastBeat = -10;
    bool armed = true;
    public long Sequence { get; private set; }
    public double Strength { get; private set; }
    public double Level { get; private set; }
    public double LowLevel { get; private set; }
    public double Drive { get; private set; }
    readonly double rate;
    public readonly GptMusicTempoTracker Tempo=new GptMusicTempoTracker();
    public double Time {get{return seconds;}}
    public GptMusicBeatDetector(int sampleRate, int channelCount) {
        if (sampleRate < 8000 || channelCount < 1 || channelCount > 32) throw new ArgumentOutOfRangeException();
        rate = sampleRate; channels = channelCount; window = Math.Max(64, sampleRate / 100);
        high = new MusicBiquad[channels]; low = new MusicBiquad[channels];
        rhythmHigh=new MusicBiquad[4,channels];rhythmLow=new MusicBiquad[4,channels];
        for(int b=0;b<4;b++)for(int c=0;c<channels;c++){rhythmHigh[b,c]=new MusicBiquad(sampleRate,220*Math.Pow(2,b),true);rhythmLow[b,c]=new MusicBiquad(sampleRate,440*Math.Pow(2,b),false);}
        for (int c = 0; c < channels; c++) { high[c] = new MusicBiquad(sampleRate, 40, true); low[c] = new MusicBiquad(sampleRate, 220, false); }
    }
    public void Push(double[] values) {
        for (int c = 0; c < channels; c++) {
            double x = values[c]; if (Double.IsNaN(x) || Double.IsInfinity(x)) x = 0;
            x = Math.Max(-1, Math.Min(1, x)); double filtered = low[c].Next(high[c].Next(x));
            for(int b=0;b<4;b++){double v=rhythmLow[b,c].Next(rhythmHigh[b,c].Next(x));rhythmEnergy[b]+=v*v;}
            broad += x * x; sum += filtered * filtered;
        }
        count++; seconds += 1 / rate;
        if (count < window) return;
        double dt=count/rate,raw=Math.Sqrt(sum/(count*channels));Level=Math.Sqrt(broad/(count*channels));
        // Smooth over several bass cycles before measuring positive energy flux.
        // A decaying reference rearms softer hits following loud ones.
        LowLevel+=(raw-LowLevel)*(1-Math.Exp(-dt/.030));
        // Scale absolute floors to recent signal energy. Measure every flux against
        // the same scale on both sides, so falling volume cannot invent an onset.
        signalPeak=Math.Max(Level,signalPeak*Math.Exp(-dt/.05));
        double signalScale=Math.Max(.001,Math.Min(1,signalPeak/.01));
        double threshold=Math.Max(.00018*signalScale,baseline*.90),rise=LowLevel-lastLow;
        peak*=Math.Exp(-dt/1.0);gainPeak=Math.Max(LowLevel,Math.Min(gainPeak*Math.Exp(-dt/2),signalPeak*1.5));
        Drive=LowLevel>.00008*signalScale&&LowLevel>Level*.10?Math.Min(1,LowLevel/Math.Max(.0006*signalScale,gainPeak))*Math.Min(1,LowLevel/(.0005*signalScale)):0;
        if(LowLevel<peak*.86||LowLevel<.00008*signalScale)armed=true;
        double onset=0;
        if (armed && seconds - lastBeat >= .17 && LowLevel > threshold &&
            LowLevel > Level * .16 && rise > Math.Max(.00004*signalScale, baseline * .065)) {
            Sequence++; lastBeat = seconds; peak = LowLevel; armed = false;
            Strength = Math.Max(.35,Math.Min(1,.45+.55*LowLevel/Math.Max(.0006*signalScale,gainPeak)));
            onset=Strength;
        }
        baseline += (LowLevel - baseline) * (1 - Math.Exp(-dt/(LowLevel<baseline?.04:.4)));
        peak=Math.Max(peak,LowLevel);
        double rhythmFlux=0;
        for(int b=0;b<4;b++){double value=Math.Sqrt(rhythmEnergy[b]/(count*channels)),floor=.0001*signalScale;rhythmFlux+=Math.Max(0,Math.Log((floor+value)/(floor+rhythmPrevious[b])))*.25;rhythmPrevious[b]=value;rhythmEnergy[b]=0;}
        Tempo.ObserveEnvelope(seconds,LowLevel,Level,rhythmFlux,signalScale);
        Tempo.Step(seconds,onset,Level>.00012*signalScale);
        lastLow = LowLevel; sum = broad = 0; count = 0;
    }
}

// Fit one tempo and phase to several consistent low-frequency onsets. Off-grid
// sounds cannot restart a pose. No raw audio or external DSP dependency is stored.
public sealed class GptMusicTempoTracker {
    readonly double[] times=new double[32],weights=new double[32];int count;
    double lastActive=-10,lastConfirmed=-10,lastEmitted=-10;
    // Derived 10 ms bass novelty only: no waveform or external audio library.
    readonly double[] novelty=new double[800];int noveltyCount,noveltyWrite;
    double previousEnvelopeLow,previousFlux,smoothedFlux,noveltyMean,nextEstimate,pendingPeriod,pendingSince,lastFluxAt=-10;int pendingMatches;
    bool envelopeClock;
    public bool Locked {get;private set;}
    public double Period {get;private set;}
    public double NextBeat {get;private set;}
    public double Confidence {get;private set;}
    public double Bpm {get{return Locked?60/Period:0;}}
    public long Sequence {get;private set;}
    public int Candidates {get{return count;}}
    public int Resets {get;private set;}
    public bool UsesBassCycle {get{return Locked&&envelopeClock;}}
    public double EnvelopeScore {get;private set;}
    public double EnvelopeBpm {get;private set;}
    public void Reset(){Locked=false;Confidence=0;count=0;lastConfirmed=lastFluxAt=-10;noveltyCount=noveltyWrite=0;previousEnvelopeLow=previousFlux=smoothedFlux=noveltyMean=pendingPeriod=0;envelopeClock=false;Resets++;}
    double Novelty(double ago){
        if(ago<0||ago+1>=noveltyCount)return 0;int n=(int)ago;
        int a=(noveltyWrite-1-n+novelty.Length)%novelty.Length,b=(a-1+novelty.Length)%novelty.Length;
        return novelty[a]+(novelty[b]-novelty[a])*(ago-n);
    }
    double Correlation(int lag,int length){
        double mean=0;for(int i=0;i<length;i++)mean+=Novelty(i);mean/=length;
        double xy=0,xx=0,yy=0;
        for(int i=0;i<length-lag;i++){double a=Novelty(i)-mean,b=Novelty(i+lag)-mean;xy+=a*b;xx+=a*a;yy+=b*b;}
        return xy/Math.Sqrt(Math.Max(1e-16,xx*yy));
    }
    // A clear kick train must not be doubled by eighth-note high hats.
    bool OnsetsSupportClock(double now){
        double total=0,matched=0;int hits=0;double first=now;
        for(int k=0;k<count;k++){
            if(now-times[k]>2.8)continue;total+=weights[k];first=Math.Min(first,times[k]);
            double nearest=NextBeat+Math.Round((times[k]-NextBeat)/Period)*Period;
            if(Math.Abs(times[k]-nearest)<Math.Min(.060,Period*.12)){matched+=weights[k];hits++;}
        }
        return hits>=4&&now-first>=Period*2.5&&matched>total*.80&&now-lastConfirmed<Period*1.4;
    }
    double PeakSamples(int lag,int length){
        double left=Correlation(lag-1,length),center=Correlation(lag,length),right=Correlation(lag+1,length);
        double curve=left-2*center+right,offset=curve<0?Math.Max(-.5,Math.Min(.5,.5*(left-right)/curve)):0;
        return Math.Max(28,Math.Min(100,lag+offset));
    }
    // A half-speed grid places alternate real hits on opposite phases.
    // Compare that evidence before accepting an octave of the beat period.
    double PhaseCoherence(double samples,int length){
        double angle=2*Math.PI/samples,cs=Math.Cos(angle),sn=Math.Sin(angle),x=1,y=0,c=0,s=0,total=0;
        for(int i=0;i<length;i++){
            double v=Novelty(i);c+=v*x;s+=v*y;total+=v;
            double next=x*cs-y*sn;y=x*sn+y*cs;x=next;
        }
        return Math.Sqrt(c*c+s*s)/Math.Max(1e-12,total);
    }
    public void ObserveEnvelope(double now,double low,double broad){ObserveEnvelope(now,low,broad,-1);}
    // Low-frequency activity remains the gate. Other drum bands corroborate
    // the tempo so a syncopated bass phrase cannot dictate the entire grid.
    public void ObserveEnvelope(double now,double low,double broad,double drumFlux){ObserveEnvelope(now,low,broad,drumFlux,1);}
    public void ObserveEnvelope(double now,double low,double broad,double drumFlux,double signalScale){
        signalScale=Math.Max(.001,Math.Min(1,signalScale));
        double floor=.0001*signalScale,flux=Math.Max(0,Math.Log((floor+low)/(floor+previousEnvelopeLow)));previousEnvelopeLow=low;
        bool bassEvidence=true;if(drumFlux>=0){
            int bassHits=0;for(int k=0;k<count;k++)if(now-times[k]<=3.3)bassHits++;
            bassEvidence=bassHits>=3;flux=.10*flux+.90*drumFlux;
        }
        if(low<.00008*signalScale||low<broad*.10)flux=0;
        smoothedFlux+=(flux-smoothedFlux)*(1-Math.Exp(-.01/.020));flux=smoothedFlux;
        novelty[noveltyWrite]=flux;noveltyWrite=(noveltyWrite+1)%novelty.Length;noveltyCount=Math.Min(novelty.Length,noveltyCount+1);
        noveltyMean+=(flux-noveltyMean)*.02;
        if(bassEvidence&&flux>Math.Max(.025,noveltyMean*.9))lastFluxAt=now;
        double peak=previousFlux;previousFlux=flux;
        if(Locked){
            double at=now-.040;
            if(bassEvidence&&envelopeClock&&peak>flux&&peak>Math.Max(.025,noveltyMean*.9)&&at-lastConfirmed>Period*.45){
                double nearest=NextBeat+Math.Round((at-NextBeat)/Period)*Period,error=at-nearest;
                if(Math.Abs(error)<Math.Min(.065,Period*.13)){
                    if(lastConfirmed>0){double n=Math.Round((at-lastConfirmed)/Period);
                        if(n>=1&&n<=3)Period+=Math.Max(-Period*.02,Math.Min(Period*.02,(at-lastConfirmed)/n-Period))*.06;}
                    Period=Math.Max(.28,Math.Min(1,Period));NextBeat+=error*.10;lastConfirmed=at;
                }
            }
        }
        if(Locked&&!envelopeClock&&OnsetsSupportClock(now)){pendingPeriod=0;return;}
        if(!bassEvidence||noveltyCount<160||now<nextEstimate||now-lastFluxAt>.25)return;
        nextEstimate=now+.20;
        int length=Math.Min(600,noveltyCount-1),bestLag=0;double best=0;
        for(int lag=28;lag<=100;lag++){
            double fundamental=Correlation(lag,length);
            if(fundamental<.10)continue;
            double score=fundamental+.5*Correlation(lag*2,length);
            if(score>best){best=score;bestLag=lag;}
        }
        if(bestLag>0){
            int half=(int)Math.Round(PeakSamples(bestLag,length)/2);
            if(half>=28){
                double baseScore=Correlation(half,length),halfScore=baseScore+.5*Correlation(half*2,length);
                if(baseScore>=.10&&baseScore>Correlation(bestLag,length)*.50&&halfScore>best*.50){
                    bestLag=half;best=halfScore;
                }
            }
        }
        EnvelopeScore=best;EnvelopeBpm=bestLag==0?0:6000.0/bestLag;
        double required=noveltyCount<320?.50:.24;
        if(bestLag==0||best<required||length<bestLag*3){pendingPeriod=0;return;}
        double samples=PeakSamples(bestLag,length),p=samples*.01;
        if(Locked){
            if(Math.Abs(p-Period)<Period*.05){Period+=(p-Period)*.12;pendingPeriod=0;return;}
            int lag=(int)Math.Round(Period*100);
            double current=(Correlation(lag,length)+.5*Correlation(lag*2,length))*PhaseCoherence(Period*100,length);
            bool supportedSubdivision=Math.Abs(Period-2*p)<Period*.05&&Correlation(bestLag,length)>Correlation(lag,length)*.50;
            if(!supportedSubdivision&&best*PhaseCoherence(samples,length)<=current){pendingPeriod=0;return;}
        }
        if(pendingPeriod>0&&Math.Abs(p-pendingPeriod)<pendingPeriod*.05)pendingMatches++;
        else{pendingSince=now;pendingMatches=1;}
        pendingPeriod=p;
        if(now-pendingSince<(Locked?1.0:.6)||pendingMatches<3)return;
        // Find the beat offset on the repeating envelope. Off-grid transients
        // contribute noise here; they cannot restart the character's pose.
        double bestEnergy=0,total=0,bestAgo=0;
        for(int phase=0;phase<bestLag;phase++){
            double energy=0;int beats=0;
            for(double ago=phase;ago<length-2;ago+=samples){energy+=Novelty(ago)+.5*(Novelty(ago-1)+Novelty(ago+1));beats++;}
            energy/=Math.Max(1,beats);total+=energy;
            if(energy>bestEnergy){bestEnergy=energy;bestAgo=phase;}
        }
        if(bestEnergy<Math.Max(.025,total/bestLag*1.8))return;
        Period=p;Locked=true;envelopeClock=true;Confidence=Math.Min(.95,.6+best*.35);lastConfirmed=now;
        NextBeat=now-bestAgo*.01-.030;
        while(NextBeat<=now)NextBeat+=Period;
    }
    public void Step(double now,double onset,bool active){
        if(active)lastActive=now;
        // Keep the evidence through the normal quiet gaps BETWEEN drum hits.
        // Silence and missing drums still expire the running clock below.
        if(now-lastActive>Math.Max(1.2,Period*1.6)){Reset();return;}
        if(onset>=.60){
            while(count>0&&(count==times.Length||now-times[0]>6)){
                Array.Copy(times,1,times,0,count-1);Array.Copy(weights,1,weights,0,count-1);count--;
            }
            times[count]=now;weights[count]=Math.Pow(onset-.35,3);count++;
            if(Locked&&!envelopeClock){
                double nearest=NextBeat+Math.Round((now-NextBeat)/Period)*Period,error=now-nearest;
                if(Math.Abs(error)<Math.Min(.060,Period*.12)){
                    if(lastConfirmed>0){double n=Math.Round((now-lastConfirmed)/Period);
                        if(n>=1&&n<=3)Period+=Math.Max(-Period*.02,Math.Min(Period*.02,(now-lastConfirmed)/n-Period))*.18;}
                    NextBeat+=error*.15;lastConfirmed=now;
                    Confidence=Math.Min(1,Confidence+.025);
                }
            }else if(!Locked&&count>=4)Acquire(now);
        }
        if(!Locked)return;
        // Syncopated bass may omit a beat. Unlock without erasing the recent
        // envelope, so a fill does not force another full warm-up. Silence and
        // endpoint discontinuities still clear everything via Reset().
        double expiry=lastConfirmed+Period*(envelopeClock?2.6:1.6);
        // Audible fills may temporarily replace the kick. Continue the SAME
        // tempo for at most one bar; new loud sounds never reset its phase.
        expiry=Math.Max(expiry,Math.Min(lastConfirmed+Period*4.2,lastFluxAt+Period*1.1));
        if(now>expiry){
            Locked=false;Confidence=0;lastConfirmed=-10;envelopeClock=false;pendingPeriod=0;return;
        }
        if(now>=NextBeat){
            if(now-lastEmitted>Period*.55){Sequence++;lastEmitted=now;}
            do{NextBeat+=Period;}while(NextBeat<=now);
        }
    }
    void Acquire(double now){
        int first=0;while(first<count&&now-times[first]>3.3)first++;
        if(count-first<4)return;
        double best=.86,bestPeriod=0,bestOrigin=0,bestLast=0;
        for(int i=first+1;i<count;i++)for(int j=Math.Max(first,i-5);j<i;j++)for(int div=1;div<=3;div++){
            double p=(times[i]-times[j])/div;if(p<.28||p>1.0)continue;
            for(int anchor=Math.Max(0,count-4);anchor<count;anchor++){
                double origin=times[anchor],total=0,matched=0,latest=-10;int hits=0,slots=0,lo=0,hi=0;ulong used=0;
                for(int k=first;k<count;k++){
                    total+=weights[k];int n=(int)Math.Round((times[k]-origin)/p);
                    if(Math.Abs(times[k]-origin-n*p)>Math.Min(.055,p*.10))continue;
                    hits++;matched+=weights[k];latest=times[k];lo=Math.Min(lo,n);hi=Math.Max(hi,n);
                    int bit=n+32;if(bit>=0&&bit<64&&(used&(1UL<<bit))==0){used|=1UL<<bit;slots++;}
                }
                double coverage=matched/total,occupancy=(double)slots/(hi-lo+1);
                if(hits<4||hi-lo<3||coverage<.72||occupancy<.72||now-latest>.08)continue;
                double score=.6*coverage+.4*occupancy-.002*Math.Abs(Math.Log(p/.5));
                if(score>best){best=score;bestPeriod=p;bestOrigin=origin;bestLast=latest;}
            }
        }
        if(bestPeriod==0)return;
        // Regress over every agreeing beat, rather than extrapolating one
        // quantized 10 ms interval into a tempo which slowly drifts away.
        double sw=0,sn=0,st=0,snn=0,snt=0;
        for(int k=first;k<count;k++){
            double n=Math.Round((times[k]-bestOrigin)/bestPeriod);
            if(Math.Abs(times[k]-bestOrigin-n*bestPeriod)>Math.Min(.055,bestPeriod*.10))continue;
            double w=weights[k];sw+=w;sn+=w*n;st+=w*times[k];snn+=w*n*n;snt+=w*n*times[k];
        }
        double denominator=sw*snn-sn*sn;
        if(denominator>0){double fitted=(sw*snt-sn*st)/denominator;
            if(Math.Abs(fitted-bestPeriod)<bestPeriod*.05){bestPeriod=fitted;bestOrigin=(st-bestPeriod*sn)/sw;}}
        Period=bestPeriod;Locked=true;Confidence=best;lastConfirmed=bestLast;
        NextBeat=bestOrigin+(Math.Floor((now-bestOrigin)/Period)+1)*Period;
    }
}

sealed class MusicBiquad {
    readonly double b0, b1, b2, a1, a2; double z1, z2;
    public MusicBiquad(double rate, double cutoff, bool high) {
        double w = 2 * Math.PI * cutoff / rate, c = Math.Cos(w), alpha = Math.Sin(w) / (2 * .707106781186548), a0 = 1 + alpha;
        b0 = (high ? (1 + c) / 2 : (1 - c) / 2) / a0;
        b1 = (high ? -(1 + c) : 1 - c) / a0; b2 = b0;
        a1 = -2 * c / a0; a2 = (1 - alpha) / a0;
    }
    public double Next(double x) { double y = b0 * x + z1; z1 = b1 * x - a1 * y + z2; z2 = b2 * x - a2 * y; return y; }
}

[StructLayout(LayoutKind.Sequential, Pack = 2)] struct MusicWaveFormat { public ushort Tag, Channels; public uint Rate, BytesPerSecond; public ushort Align, Bits, ExtraSize; }
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MusicDeviceEnumeratorClass { }
[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface MusicDeviceEnumerator {
    [PreserveSig] int EnumAudioEndpoints(int flow, uint mask, out IntPtr devices);
    [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IMusicDevice device);
    [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMusicDevice device);
    [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr callback);
    [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr callback);
}
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IMusicDevice {
    [PreserveSig] int Activate(ref Guid iid, uint context, IntPtr parameters, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
    [PreserveSig] int OpenPropertyStore(uint mode, out IntPtr store);
    [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    [PreserveSig] int GetState(out uint state);
}
[ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IMusicAudioClient {
    [PreserveSig] int Initialize(int mode, uint flags, long duration, long period, IntPtr format, IntPtr session);
    [PreserveSig] int GetBufferSize(out uint frames);
    [PreserveSig] int GetStreamLatency(out long latency);
    [PreserveSig] int GetCurrentPadding(out uint frames);
    [PreserveSig] int IsFormatSupported(int mode, IntPtr format, out IntPtr closest);
    [PreserveSig] int GetMixFormat(out IntPtr format);
    [PreserveSig] int GetDevicePeriod(out long normal, out long minimum);
    [PreserveSig] int Start(); [PreserveSig] int Stop(); [PreserveSig] int Reset();
    [PreserveSig] int SetEventHandle(IntPtr handle);
    [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
}
[ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IMusicCaptureClient {
    [PreserveSig] int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong position, out ulong qpc);
    [PreserveSig] int ReleaseBuffer(uint frames);
    [PreserveSig] int GetNextPacketSize(out uint frames);
}

// Windows process loopback keeps game and chat audio out of the music clock.
// Unavailable/ambiguous media sessions retain the existing endpoint capture.
sealed class GptMusicPlaybackSource {
    object manager;Type managerType,sessionType;System.Threading.Tasks.Task request;
    public string Error {get;private set;}
    public uint Find() {
        try {
            if(managerType==null){
                managerType=Type.GetType("Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType=WindowsRuntime",true);
                sessionType=Type.GetType("Windows.Media.Control.GlobalSystemMediaTransportControlsSession, Windows.Media.Control, ContentType=WindowsRuntime",true);
                var extension=Type.GetType("System.WindowsRuntimeSystemExtensions, System.Runtime.WindowsRuntime, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089",true);
                var operation=managerType.GetMethod("RequestAsync").Invoke(null,null);
                foreach(var m in extension.GetMethods())if(m.Name=="AsTask"&&m.IsGenericMethodDefinition&&m.GetGenericArguments().Length==1&&m.GetParameters().Length==1){
                    request=(System.Threading.Tasks.Task)m.MakeGenericMethod(managerType).Invoke(null,new object[]{operation});break;
                }
            }
            if(manager==null){if(request==null||!request.Wait(75))return 0;manager=request.GetType().GetProperty("Result").GetValue(request,null);}
            object session=managerType.GetMethod("GetCurrentSession").Invoke(manager,null);if(session==null)return 0;
            string source=(string)sessionType.GetProperty("SourceAppUserModelId").GetValue(session,null);
            if(String.IsNullOrEmpty(source)||!source.EndsWith(".exe",StringComparison.OrdinalIgnoreCase))return 0;
            string name=System.IO.Path.GetFileNameWithoutExtension(source);uint active=0,inactive=0;bool activeAmbiguous=false,inactiveAmbiguous=false;
            MusicDeviceEnumerator enumerator=null;IMusicDevice device=null;object activated=null;GptMusicSessionEnumerator sessions=null;
            try{
                enumerator=(MusicDeviceEnumerator)new MusicDeviceEnumeratorClass();Check(enumerator.GetDefaultAudioEndpoint(0,1,out device));
                Guid iid=typeof(GptMusicSessionManager).GUID;Check(device.Activate(ref iid,23,IntPtr.Zero,out activated));
                Check(((GptMusicSessionManager)activated).GetSessionEnumerator(out sessions));int n;Check(sessions.GetCount(out n));
                for(int i=0;i<n;i++){
                    object control=null;
                    try{
                        Check(sessions.GetSession(i,out control));var c=(GptMusicSessionControl)control;uint pid;int state;Check(c.GetProcessId(out pid));Check(c.GetState(out state));
                        if(state==2||pid==0)continue;
                        using(var p=Process.GetProcessById((int)pid)){
                            if(!String.Equals(p.ProcessName,name,StringComparison.OrdinalIgnoreCase))continue;
                            if(state==1){if(active!=0&&active!=pid)activeAmbiguous=true;active=pid;}else{if(inactive!=0&&inactive!=pid)inactiveAmbiguous=true;inactive=pid;}
                        }
                    }catch(ArgumentException){}finally{Release(control);}
                }
            }finally{Release(sessions);Release(activated);Release(device);Release(enumerator);}
            Error=null;return active!=0?(activeAmbiguous?0:active):(inactiveAmbiguous?0:inactive);
        }catch(Exception e){Error=e.GetType().Name;return 0;}
    }
    static void Check(int hr){if(hr<0)Marshal.ThrowExceptionForHR(hr);}
    static void Release(object o){if(o!=null&&Marshal.IsComObject(o))Marshal.FinalReleaseComObject(o);}
}
[ComImport,Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]interface GptMusicSessionManager {
    [PreserveSig]int GetAudioSessionControl(IntPtr id,uint flags,out IntPtr control);
    [PreserveSig]int GetSimpleAudioVolume(IntPtr id,uint flags,out IntPtr volume);
    [PreserveSig]int GetSessionEnumerator(out GptMusicSessionEnumerator list);
}
[ComImport,Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]interface GptMusicSessionEnumerator {
    [PreserveSig]int GetCount(out int count);[PreserveSig]int GetSession(int index,[MarshalAs(UnmanagedType.IUnknown)]out object control);
}
[ComImport,Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]interface GptMusicSessionControl {
    [PreserveSig]int GetState(out int state);[PreserveSig]int GetDisplayName(out IntPtr name);
    [PreserveSig]int SetDisplayName(IntPtr name,IntPtr context);[PreserveSig]int GetIconPath(out IntPtr path);[PreserveSig]int SetIconPath(IntPtr path,IntPtr context);
    [PreserveSig]int GetGroupingParam(out Guid id);[PreserveSig]int SetGroupingParam(IntPtr id,IntPtr context);[PreserveSig]int RegisterNotification(IntPtr listener);[PreserveSig]int UnregisterNotification(IntPtr listener);
    [PreserveSig]int GetSessionIdentifier(out IntPtr id);[PreserveSig]int GetSessionInstanceIdentifier(out IntPtr id);[PreserveSig]int GetProcessId(out uint pid);
}
[ComVisible(true),Guid("41D949AB-9862-444A-80F6-C261334DA5EB"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]public interface GptMusicActivationCompleted {
    [PreserveSig]int ActivateCompleted(GptMusicActivationOperation operation);
}
[ComImport,Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]public interface GptMusicActivationOperation {
    [PreserveSig]int GetActivateResult(out int result,[MarshalAs(UnmanagedType.IUnknown)]out object audio);
}
[ComVisible(true),Guid("94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]public interface GptMusicAgileObject {}
[StructLayout(LayoutKind.Sequential)]struct GptMusicActivationBlob {public ushort Type,R1,R2,R3;public uint Size;public IntPtr Data;}
[ComVisible(true),ClassInterface(ClassInterfaceType.None)]public sealed class GptMusicProcessActivator : GptMusicActivationCompleted,GptMusicAgileObject {
    readonly object gate=new object();readonly ManualResetEvent ready=new ManualResetEvent(false);int references=2,result;object audio;bool abandoned;IntPtr data,variant;
    [DllImport("Mmdevapi.dll",ExactSpelling=true,CharSet=CharSet.Unicode)]static extern int ActivateAudioInterfaceAsync(string path,ref Guid iid,IntPtr blob,GptMusicActivationCompleted callback,out GptMusicActivationOperation operation);
    void ReleaseWait(){if(Interlocked.Decrement(ref references)==0)ready.Dispose();}
    void FreeParameters(){if(variant!=IntPtr.Zero){Marshal.FreeHGlobal(variant);variant=IntPtr.Zero;}if(data!=IntPtr.Zero){Marshal.FreeHGlobal(data);data=IntPtr.Zero;}}
    public int ActivateCompleted(GptMusicActivationOperation operation){
        object value=null;int hr=0;
        try{int activation;hr=operation.GetActivateResult(out activation,out value);if(hr>=0)hr=activation;
            lock(gate){result=hr;if(abandoned){if(value!=null)Marshal.FinalReleaseComObject(value);}else audio=value;}
        }catch(Exception e){lock(gate){result=Marshal.GetHRForException(e);}}
        finally{FreeParameters();ready.Set();ReleaseWait();}return 0;
    }
    public static object Open(uint pid,WaitHandle stop){
        var h=new GptMusicProcessActivator();GptMusicActivationOperation operation=null;
        h.data=Marshal.AllocHGlobal(12);Marshal.WriteInt32(h.data,0,1);Marshal.WriteInt32(h.data,4,(int)pid);Marshal.WriteInt32(h.data,8,0);
        var blob=new GptMusicActivationBlob{Type=65,Size=12,Data=h.data};h.variant=Marshal.AllocHGlobal(Marshal.SizeOf(blob));Marshal.StructureToPtr(blob,h.variant,false);
        try{
            Guid iid=typeof(IMusicAudioClient).GUID;int hr=ActivateAudioInterfaceAsync("VAD\\Process_Loopback",ref iid,h.variant,h,out operation);
            if(hr<0){h.FreeParameters();h.ReleaseWait();Marshal.ThrowExceptionForHR(hr);}
            int wait=WaitHandle.WaitAny(new WaitHandle[]{h.ready,stop},1500);
            lock(h.gate){
                if(wait!=0){h.abandoned=true;if(h.audio!=null){Marshal.FinalReleaseComObject(h.audio);h.audio=null;}if(wait==1)throw new OperationCanceledException();throw new TimeoutException("Music process capture activation timed out.");}
                if(h.result<0){if(h.audio!=null){Marshal.FinalReleaseComObject(h.audio);h.audio=null;}Marshal.ThrowExceptionForHR(h.result);}object audio=h.audio;h.audio=null;return audio;
            }
        }finally{if(operation!=null)Marshal.FinalReleaseComObject(operation);h.ReleaseWait();}
    }
    public static IntPtr Format(){
        var f=new MusicWaveFormat{Tag=3,Channels=2,Rate=48000,BytesPerSecond=384000,Align=8,Bits=32};
        IntPtr p=Marshal.AllocCoTaskMem(Marshal.SizeOf(f));Marshal.StructureToPtr(f,p,false);return p;
    }
}
