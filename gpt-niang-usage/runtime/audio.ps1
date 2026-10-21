# Preloaded, volume-scaled PCM; native playback stays on one audio worker.
if ($null -eq (Get-Variable -Name gptNiangAudio -Scope Script -ErrorAction SilentlyContinue)) {
    $script:gptNiangAudio = $null
}

function Get-WidgetAudioEnabled {
    $setting = Get-Variable -Name soundOn -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $setting) { return $true }
    return ($setting.Value -ne $false)
}

function Get-WidgetAudioVolume {
    $setting = Get-Variable -Name soundVolume -Scope Script -ErrorAction SilentlyContinue
    $value = 0.9
    if ($null -ne $setting) {
        try { $value = [double]$setting.Value } catch { $value = 0.9 }
    }
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { $value = 0.9 }
    return [Math]::Min(1.0, [Math]::Max(0.0, $value))
}

if(!('GptNiangPcm' -as [type])){
    Add-Type -TypeDefinition @'
using System;
public static class GptNiangPcm {
 public static byte[] Scale(byte[] source,int offset,int length,double volume){
  var output=(byte[])source.Clone();
  for(int i=offset;i<offset+length;i+=2){
   int value=(short)(source[i]|(source[i+1]<<8));
   int scaled=(int)Math.Round(value*volume,MidpointRounding.AwayFromZero);
   short sample=(short)Math.Max(-32768,Math.Min(32767,scaled));
   output[i]=(byte)(sample&255);output[i+1]=(byte)((sample>>8)&255);
  }
  return output;
 }
}
'@
}
if(!('GptClickAudioQueue' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Threading;
public sealed class GptClickAudioQueue : IDisposable {
 [DllImport("winmm.dll", EntryPoint="PlaySoundW")]
 [return: MarshalAs(UnmanagedType.Bool)]
 private static extern bool PlaySound(IntPtr sound, IntPtr module, uint flags);
 // One pending command: a blocked driver must not accumulate stale clicks.
 private readonly BlockingCollection<byte[]> queue=new BlockingCollection<byte[]>(1);
 private readonly Thread worker;
 private readonly Func<IntPtr,uint,bool> play;
 private static readonly object gate=new object();
 private static GptClickAudioQueue owner;
 private GCHandle current;
 private bool closed;
 private volatile string error;
 public string Error { get { return error; } }
 public bool IsRunning { get { return worker.IsAlive; } }
 public GptClickAudioQueue() : this((sound,flags)=>PlaySound(sound,IntPtr.Zero,flags)) {}
 public GptClickAudioQueue(Func<IntPtr,uint,bool> playback){
  play=playback;
  worker=new Thread(Loop);worker.IsBackground=true;worker.Name="gpt-click-audio";worker.Start();
 }
 private static void Reset(){
  if(owner==null)return;
  // Keep asynchronous PCM memory pinned until native playback really stops.
  if(!owner.play(IntPtr.Zero,0))throw new InvalidOperationException("Audio stop failed");
  if(owner.current.IsAllocated)owner.current.Free();
  owner=null;
 }
 private void Run(byte[] wave){
  lock(gate){
   for(int attempt=0;attempt<2;attempt++){
    try{
     Reset();
     if(wave==null){error=null;return;}
     current=GCHandle.Alloc(wave,GCHandleType.Pinned);owner=this;
     // SoundPlayer discards this BOOL; inspect it and reset/retry once instead.
     if(play(current.AddrOfPinnedObject(),0x0007)){error=null;return;}
     error="Audio playback failed";
    }catch(Exception ex){error=ex.Message;}
   }
  }
 }
 private void Loop(){
  try{foreach(byte[] wave in queue.GetConsumingEnumerable()){
   if(queue.IsAddingCompleted)break;
   Run(wave);
  }}finally{
   lock(gate){if(owner==this){try{Reset();}catch(Exception ex){error=ex.Message;}}}
   lock(queue){closed=true;queue.Dispose();}
  }
 }
 public void Play(byte[] wave){
  lock(queue){
   if(closed)return;
   if(!queue.TryAdd(wave)){byte[] stale;queue.TryTake(out stale);queue.TryAdd(wave);}
  }
 }
 public void Stop(){Play(null);}
 public void Dispose(){lock(queue){if(!closed){closed=true;queue.CompleteAdding();}}}
 public void Wait(int milliseconds){worker.Join(milliseconds);}
}
'@
}
function Read-WidgetPcmWave([string]$Path,[double]$MaxSeconds=5) {
    if([double]::IsNaN($MaxSeconds) -or [double]::IsInfinity($MaxSeconds) -or $MaxSeconds -le 0 -or $MaxSeconds -gt 120){throw 'Invalid WAV duration limit.'}
    $file=[IO.File]::OpenRead($Path)
    try{
        if($file.Length -gt 10MB){throw '音效文件超过10MiB。'}
        $bytes=[byte[]]::new([int]$file.Length);$read=0
        while($read -lt $bytes.Length){$n=$file.Read($bytes,$read,$bytes.Length-$read);if(!$n){throw 'WAV文件不完整。'};$read+=$n}
        if($file.Length -ne $bytes.Length){throw '音效读取期间发生变化，请重试。'}
    }finally{$file.Dispose()}
    if($bytes.Length -lt 12 -or [Text.Encoding]::ASCII.GetString($bytes,0,4) -ne 'RIFF' -or [Text.Encoding]::ASCII.GetString($bytes,8,4) -ne 'WAVE' -or [long][BitConverter]::ToUInt32($bytes,4)+8 -ne $bytes.Length){throw 'WAV文件损坏或不完整。'}
    $formatSeen=$false;$dataSeen=$false;$offset=12;$dataOffset=0;$dataLength=0;$rate=0;$align=0
    while($offset -lt $bytes.Length){
        if($offset+8 -gt $bytes.Length){throw 'WAV文件不完整。'}
        $tag=[Text.Encoding]::ASCII.GetString($bytes,$offset,4);$size=[long][BitConverter]::ToUInt32($bytes,$offset+4);$body=$offset+8
        if($size+($size%2) -gt $bytes.Length-$body){throw 'WAV数据块不完整。'}
        if($tag -eq 'fmt '){
            if($formatSeen -or $size -lt 16){throw 'WAV格式块无效。'};$formatSeen=$true
            $channels=[BitConverter]::ToUInt16($bytes,$body+2);$rate=[BitConverter]::ToUInt32($bytes,$body+4);$align=[BitConverter]::ToUInt16($bytes,$body+12)
            if([BitConverter]::ToUInt16($bytes,$body) -ne 1 -or [BitConverter]::ToUInt16($bytes,$body+14) -ne 16 -or $channels -notin @(1,2) -or $rate -lt 8000 -or $rate -gt 192000 -or $align -ne $channels*2 -or [BitConverter]::ToUInt32($bytes,$body+8) -ne [long]$rate*$align){throw '缓存不是有效的16位PCM WAV。'}
        }elseif($tag -eq 'data'){
            if($dataSeen){throw 'WAV文件有重复音频块。'};$dataSeen=$true;$dataOffset=$body;$dataLength=[int]$size
        }
        $offset=$body+$size+($size%2)
    }
    if(!$formatSeen -or !$dataSeen -or $dataLength -le 0 -or $dataLength%$align -ne 0){throw 'WAV音频数据无效。'}
    if([long]$dataLength -gt [long]$rate*$align*$MaxSeconds){throw '音频时长超过允许范围。'}
    return @{Bytes=$bytes;Offset=$dataOffset;Length=$dataLength;Duration=([double]$dataLength/$align/$rate)}
}
function Get-WidgetWaveSeconds([string]$Path,[double]$MaxSeconds=5){return (Read-WidgetPcmWave $Path $MaxSeconds).Duration}
function New-WidgetAudioClip([string]$Path,[double]$Volume,[double]$MaxSeconds=5) {
    $wave=Read-WidgetPcmWave $Path $MaxSeconds
    return ,([GptNiangPcm]::Scale($wave.Bytes,$wave.Offset,$wave.Length,$Volume))
}
function New-WidgetScaledSoundPlayer([string]$Path,[double]$Volume,[double]$MaxSeconds=5) {
    $wave=Read-WidgetPcmWave $Path $MaxSeconds
    $scaled=[GptNiangPcm]::Scale($wave.Bytes,$wave.Offset,$wave.Length,$Volume)
    $stream=[IO.MemoryStream]::new($scaled)
    try{
        $player=[System.Media.SoundPlayer]::new($stream);$player.Load()
        return [pscustomobject]@{Player=$player;Stream=$stream}
    }catch{$stream.Dispose();throw}
}
function Close-WidgetSoundPlayer($Player,$Stream) {
    if($null -ne $Player){try{$Player.Stop()}catch{};try{$Player.Dispose()}catch{}}
    if($null -ne $Stream){try{$Stream.Dispose()}catch{}}
}
function Read-WidgetAudioPreferences([string]$DataDir) {
    $prefs=@{version=1;mode='builtin';press=$null;release=$null}
    if(!$DataDir){return $prefs}
    $file=Join-Path $DataDir 'audio-preferences.json'
    if(![IO.File]::Exists($file)){return $prefs}
    try{
        if((Get-Item -LiteralPath $file).Length-gt 16KB){throw 'Invalid audio preferences'}
        $saved=Get-Content -LiteralPath $file -Raw -Encoding UTF8|ConvertFrom-Json
        if($saved.version-ne 1 -or $saved.mode-notin @('builtin','custom')){throw 'Invalid audio preferences'}
        $prefs.mode=[string]$saved.mode
        foreach($slot in @('press','release')){
            $entry=$saved.$slot
            if($null-eq $entry){continue}
            if($entry.file-isnot [string] -or $entry.file-cnotmatch '^[a-f0-9]{32}\.wav$' -or $entry.name-isnot [string] -or $entry.name.Length-gt 255){throw 'Invalid audio entry'}
            $prefs[$slot]=@{file=$entry.file;name=$entry.name}
        }
    }catch{$prefs=@{version=1;mode='custom';press=$null;release=$null;loadError='音效设置无法读取，请重新选择音效。'}}
    return $prefs
}
function Copy-WidgetAudioPreferences($Preferences) {
    $copy=@{version=1;mode=$Preferences.mode;press=$null;release=$null}
    foreach($slot in @('press','release')){if($Preferences[$slot]){$copy[$slot]=@{file=$Preferences[$slot].file;name=$Preferences[$slot].name}}}
    return $copy
}
function Write-WidgetAudioPreferences([string]$DataDir,$Preferences) {
    if(!$DataDir){throw '个人音效目录不可用。'}
    $file=Join-Path $DataDir 'audio-preferences.json';$temporary=$file+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temporary,($Preferences|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        if([IO.File]::Exists($file)){[IO.File]::Replace($temporary,$file,($file+'.bak'),$true)}else{[IO.File]::Move($temporary,$file)}
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
function Get-WidgetCustomAudioPath($Audio,[string]$Slot) {
    $entry=$Audio.Preferences[$Slot]
    if(!$entry -or !$Audio.DataDir){return $null}
    return Join-Path (Join-Path $Audio.DataDir 'sounds') $entry.file
}
function Close-WidgetAudioState($Audio) {
    if(!$Audio){return}
    $Audio.Timer.Stop()
    if($Audio.Queue){try{$Audio.Queue.Dispose();$Audio.Queue.Wait(500)}catch{}}
    $Audio.Press=$null;$Audio.Release=$null
}
function New-WidgetAudioState([string]$AppDir,[string]$DataDir,$Preferences) {
    $timer=[Windows.Threading.DispatcherTimer]::new()
    $audio=@{AppDir=$AppDir;DataDir=$DataDir;Preferences=$Preferences;Errors=@{}
        Press=$null;Release=$null;PressPath=$null;ReleasePath=$null
        Volume=(Get-WidgetAudioVolume);Timer=$timer;Clock=[Diagnostics.Stopwatch]::new()
        Queue=[GptClickAudioQueue]::new()
        Duration=0.0;Pressing=$false;PressEnded=$true;PendingRelease=$false;ReleasePlayed=$true}
    try{
        foreach($slot in @('press','release')){
            $source=if($Preferences.mode-eq 'builtin'){Join-Path $AppDir ('assets/'+$slot+'.wav')}else{Get-WidgetCustomAudioPath $audio $slot}
            $audio[$slot+'Path']=$source
            if(!$source){continue}
            try{
                $duration=Get-WidgetWaveSeconds $source
                $loaded=New-WidgetAudioClip $source $audio.Volume
                $audio[$slot]=$loaded
                if($slot-eq 'press'){$audio.Duration=$duration}
            }catch{
                if($Preferences.mode-eq 'builtin'){throw}
                $audio.Errors[$slot]='文件不可用，请重新选择。'
            }
        }
        $timer.Add_Tick({
            param($sender,$event)
            $audio=$script:gptNiangAudio
            if(!$audio -or ![object]::ReferenceEquals($sender,$audio.Timer)){return}
            $audio.Timer.Stop()
            if(!$audio.PendingRelease -or $audio.Pressing){return}
            $remaining=$audio.Duration+0.06-$audio.Clock.Elapsed.TotalSeconds
            if($remaining-gt 0.002){$audio.Timer.Interval=[TimeSpan]::FromSeconds($remaining);$audio.Timer.Start();return}
            $audio.PressEnded=$true;Invoke-WidgetReleaseNow
        })
        return $audio
    }catch{Close-WidgetAudioState $audio;throw}
}
function Set-WidgetAudioVolume {
    param([double]$Volume=-1)
    if($Volume-ge 0 -and ![double]::IsNaN($Volume) -and ![double]::IsInfinity($Volume)){$script:soundVolume=[Math]::Min(1.0,[Math]::Max(0.0,$Volume))}
    $value=Get-WidgetAudioVolume;$audio=$script:gptNiangAudio
    if(!$audio -or [Math]::Abs($audio.Volume-$value)-lt 0.000001){return}
    $clips=@{}
    try{
        foreach($slot in @('press','release')){if($audio[$slot]){$clips[$slot]=New-WidgetAudioClip $audio[$slot+'Path'] $value}}
        foreach($slot in @('press','release')){
            if(!$clips[$slot]){continue}
            $audio[$slot]=$clips[$slot]
        }
        $audio.Volume=$value
        $audio.Queue.Stop()
    }catch{
        $script:soundVolume=$audio.Volume
    }
}
function Invoke-WidgetReleaseNow {
    $audio=$script:gptNiangAudio
    if(!$audio -or !$audio.PendingRelease -or $audio.ReleasePlayed){return}
    $audio.Timer.Stop();$audio.PendingRelease=$false;$audio.ReleasePlayed=$true
    if(!(Get-WidgetAudioEnabled) -or (Get-WidgetAudioVolume)-le 0 -or !$audio.Release){return}
    Set-WidgetAudioVolume
    # Native stop/play and recovery stay on the audio worker, away from dragging.
    if($audio.Queue){try{$audio.Queue.Play($audio.Release)}catch{}}
}
function Stop-WidgetAudio {
    $audio=$script:gptNiangAudio
    if(!$audio){return}
    $audio.Timer.Stop();$audio.PendingRelease=$false;$audio.ReleasePlayed=$true;$audio.Pressing=$false;$audio.PressEnded=$true;$audio.Clock.Reset()
    if($audio.Queue){try{$audio.Queue.Stop()}catch{}}
}
function Initialize-WidgetAudio {
    param([Parameter(Mandatory=$true)][string]$AppDir,[string]$DataDir)
    Close-WidgetAudio
    try{
        Add-Type -AssemblyName PresentationCore,WindowsBase,System
        $prefs=Read-WidgetAudioPreferences $DataDir
        $script:gptNiangAudio=New-WidgetAudioState $AppDir $DataDir $prefs
    }catch{$script:gptNiangAudio=$null}
}
function Close-WidgetAudio {
    if(!$script:gptNiangAudio){return}
    Stop-WidgetAudio;Close-WidgetAudioState $script:gptNiangAudio;$script:gptNiangAudio=$null
}
function Play-WidgetPressSound {
    if((Get-Command Test-QuoteVoiceBusy -ErrorAction SilentlyContinue) -and (Test-QuoteVoiceBusy)){return}
    if((Get-Command Test-CompletionVoiceBusy -ErrorAction SilentlyContinue) -and (Test-CompletionVoiceBusy)){return}
    $audio=$script:gptNiangAudio
    if(!$audio){return}
    $audio.Timer.Stop();$audio.PendingRelease=$false;$audio.PressEnded=$true;$audio.Clock.Reset()
    if(!(Get-WidgetAudioEnabled) -or (Get-WidgetAudioVolume)-le 0 -or (!$audio.Press -and !$audio.Release)){$audio.Pressing=$false;return}
    $audio.Pressing=$true;$audio.PressEnded=(!$audio.Press);$audio.ReleasePlayed=$false;$audio.Clock.Restart()
    Set-WidgetAudioVolume
    # Keep the original stop-then-play sequence without waiting on the UI thread.
    if($audio.Press -and $audio.Queue){try{$audio.Queue.Play($audio.Press)}catch{$audio.PressEnded=$true}}
}
function Play-WidgetReleaseSound {
    if((Get-Command Test-QuoteVoiceBusy -ErrorAction SilentlyContinue) -and (Test-QuoteVoiceBusy)){return}
    if((Get-Command Test-CompletionVoiceBusy -ErrorAction SilentlyContinue) -and (Test-CompletionVoiceBusy)){return}
    $audio=$script:gptNiangAudio
    if(!$audio -or !$audio.Pressing){return}
    $audio.Pressing=$false
    if(!(Get-WidgetAudioEnabled) -or (Get-WidgetAudioVolume)-le 0){Stop-WidgetAudio;return}
    if(!$audio.Release){$audio.ReleasePlayed=$true;return}
    $audio.PendingRelease=$true
    if(!$audio.Press -or $audio.PressEnded){Invoke-WidgetReleaseNow;return}
    $remaining=$audio.Duration+0.06-$audio.Clock.Elapsed.TotalSeconds
    if($remaining-le 0.002){$audio.PressEnded=$true;Invoke-WidgetReleaseNow;return}
    $audio.Timer.Interval=[TimeSpan]::FromSeconds($remaining);$audio.Timer.Start()
}
function Remove-WidgetUnusedAudioFiles($Audio,$Preferences) {
    # Replaced or cleared custom clips otherwise stay in the user's data folder
    # forever. Only files inside our own sounds directory are considered.
    if(!$Audio -or !$Audio.DataDir -or !$Preferences){return}
    $keep=@{}
    foreach($slot in @('press','release')){$entry=$Preferences[$slot];if($entry -and $entry.file){$keep[[string]$entry.file]=$true}}
    $directory=Join-Path $Audio.DataDir 'sounds'
    try{
        foreach($file in [IO.Directory]::GetFiles($directory,'*.wav')){
            if(!$keep.ContainsKey([IO.Path]::GetFileName($file))){try{[IO.File]::Delete($file)}catch{}}
        }
    }catch{}
}
function Set-WidgetAudioPreferences($Preferences,[string]$RequiredSlot) {
    $audio=$script:gptNiangAudio
    if(!$audio){throw '声音播放器尚未就绪。'}
    $candidate=$null
    try{
        $candidate=New-WidgetAudioState $audio.AppDir $audio.DataDir $Preferences
        if($RequiredSlot -and !$candidate[$RequiredSlot]){throw '音效无法加载，原设置已保留。'}
        Write-WidgetAudioPreferences $audio.DataDir $Preferences
    }catch{Close-WidgetAudioState $candidate;throw}
    Close-WidgetAudio;$script:gptNiangAudio=$candidate
}
function Import-WidgetAudio([ValidateSet('press','release')][string]$Slot,[string]$Path) {
    if(!$Path){return $false}
    $audio=$script:gptNiangAudio
    if(!$audio -or !$audio.DataDir){throw '个人音效目录不可用。'}
    $directory=Join-Path $audio.DataDir 'sounds';$null=[IO.Directory]::CreateDirectory($directory)
    $filename=[Guid]::NewGuid().ToString('N')+'.wav';$target=Join-Path $directory $filename
    $process=$null;$committed=$false
    try{
        $node=if($script:config.nodePath){$script:config.nodePath}else{(Get-Command node -ErrorAction Stop).Source}
        $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$node
        $info.Arguments='"'+(Join-Path $audio.AppDir 'runtime/audio-import.mjs')+'" "'+[IO.Path]::GetFullPath($Path)+'" "'+$target+'"'
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
        $process=[Diagnostics.Process]::new();$process.StartInfo=$info
        if(!$process.Start()){throw '音效转换无法启动。'}
        if(!$process.WaitForExit(5000)){$process.Kill();$null=$process.WaitForExit(1000);throw '音效读取超时，请换一个文件。'}
        $result=$process.StandardOutput.ReadToEnd()|ConvertFrom-Json
        if(!$result.ok -or $process.ExitCode-ne 0){
            $message=switch($result.error){
                'too_long'{'音效超过5秒，请选择不超过5秒的文件。'}
                'too_large'{'音效文件超过10MiB，请选择较小的文件。'}
                'unsupported'{'不支持这种WAV编码，请选择其他音效文件。'}
                'io'{'无法读取或保存音效，请检查文件和个人目录。'}
                default{'WAV文件损坏或不完整，无法导入。'}
            }
            throw $message
        }
        $prefs=Copy-WidgetAudioPreferences $audio.Preferences
        $prefs.mode='custom';$prefs[$Slot]=@{file=$filename;name=[IO.Path]::GetFileName($Path)}
        Set-WidgetAudioPreferences $prefs $Slot;Remove-WidgetUnusedAudioFiles $script:gptNiangAudio $prefs;$committed=$true;return $true
    }finally{
        if($process){$process.Dispose()}
        if(!$committed -and [IO.File]::Exists($target)){[IO.File]::Delete($target)}
    }
}
function Set-WidgetAudioMode([ValidateSet('builtin','custom')][string]$Mode) {
    $prefs=Copy-WidgetAudioPreferences $script:gptNiangAudio.Preferences;$prefs.mode=$Mode
    Set-WidgetAudioPreferences $prefs;Remove-WidgetUnusedAudioFiles $script:gptNiangAudio $prefs
}
function Clear-WidgetAudioSlot([ValidateSet('press','release')][string]$Slot) {
    $prefs=Copy-WidgetAudioPreferences $script:gptNiangAudio.Preferences;$prefs.mode='custom';$prefs[$Slot]=$null
    Set-WidgetAudioPreferences $prefs;Remove-WidgetUnusedAudioFiles $script:gptNiangAudio $prefs
}
function Invoke-WidgetAudioPreview([ValidateSet('press','release')][string]$Slot) {
    $audio=$script:gptNiangAudio
    if(!$audio -or !(Get-WidgetAudioEnabled) -or (Get-WidgetAudioVolume)-le 0){return}
    $source=Get-WidgetCustomAudioPath $audio $Slot
    if(!$source){return}
    Stop-WidgetAudio
    try{
        $clip=New-WidgetAudioClip $source (Get-WidgetAudioVolume)
        $audio.Queue.Play($clip)
    }catch{throw ($audio.Preferences[$Slot].name+[Environment]::NewLine+'音效文件不可用，请重新选择。')}
}
function Select-WidgetAudioFile {
    $dialog=[Microsoft.Win32.OpenFileDialog]::new()
    $dialog.Title='选择WAV音效，最长5秒';$dialog.Filter='WAV音效 (*.wav)|*.wav';$dialog.Multiselect=$false;$dialog.CheckFileExists=$true
    if($dialog.ShowDialog($script:window)-eq $true){return $dialog.FileName}
    return $null
}
function Show-WidgetAudioError([string]$Message) {
    [Windows.MessageBox]::Show($script:window,$Message,'GPT 娘 · 音效',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Warning)|Out-Null
}
function Invoke-WidgetAudioAction([string]$Action,[string]$Slot) {
    $script:audioDialogOpen=$true
    try{
        switch($Action){
            'import'{$source=Select-WidgetAudioFile;if($source){try{$null=Import-WidgetAudio $Slot $source}catch{throw ([IO.Path]::GetFileName($source)+[Environment]::NewLine+$_.Exception.Message)}}}
            'clear'{Clear-WidgetAudioSlot $Slot}
            'builtin'{Set-WidgetAudioMode 'builtin'}
            'custom'{Set-WidgetAudioMode 'custom'}
            'preview'{Invoke-WidgetAudioPreview $Slot}
        }
    }catch{Show-WidgetAudioError $_.Exception.Message}
    finally{$script:audioDialogOpen=$false;Update-WidgetSettingsMenu}
}
function Get-WidgetAudioStatus {
    $audio=$script:gptNiangAudio
    $status=@{enabled=(Get-WidgetAudioEnabled);volume=(Get-WidgetAudioVolume);backend=$null;ready=[bool]$audio;mode='builtin';press=$null;release=$null}
    if(!$audio){return $status}
    $status.mode=$audio.Preferences.mode;$status.error=$audio.Preferences.loadError
    if($audio.Queue.Error){$status.error=$audio.Queue.Error}
    if($audio.Press -or $audio.Release){$status.backend='winmm.PlaySound'}
    foreach($slot in @('press','release')){
        $entry=$audio.Preferences[$slot];$source=Get-WidgetCustomAudioPath $audio $slot
        $status[$slot]=@{name=if($entry){$entry.name}else{'无声'};configured=[bool]$entry;available=([bool]$source -and [IO.File]::Exists($source) -and !$audio.Errors[$slot]);active=[bool]$audio[$slot];error=$audio.Errors[$slot]}
    }
    return $status
}
