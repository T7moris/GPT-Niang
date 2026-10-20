param([switch]$Live,[string]$ResultFile,[double]$PlaybackSeconds=3.3)
$ErrorActionPreference='Stop'
$app=Split-Path $PSScriptRoot -Parent
$helper=@'
public static class GptMusicAudioProbe {
 public static int Signal(int rate,int channels,double frequency,double gain,bool pulsed,bool opposite) {
  var detector=new GptMusicBeatDetector(rate,channels);var row=new double[channels];
  int frames=(int)(rate*3.3);
  for(int i=0;i<frames;i++){
   double t=(double)i/rate,local=t-.3-Math.Floor((t-.3)/.5)*.5;
   double envelope=t<.3?0:(pulsed?(local<.14?Math.Min(1,local/.005)*Math.Exp(-local/0.045):0):1);
   double x=gain*envelope*Math.Sin(2*Math.PI*frequency*t);
   for(int c=0;c<channels;c++)row[c]=opposite&&c%2==1?-x:x;
   detector.Push(row);
  }
  return (int)detector.Sequence;
 }
 public static byte[] Wave(int rate,double seconds) {
  int frames=(int)(rate*seconds);var bytes=new byte[44+frames*4];
  using(var stream=new System.IO.MemoryStream(bytes))using(var w=new System.IO.BinaryWriter(stream)){
   w.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));w.Write(bytes.Length-8);w.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt "));
   w.Write(16);w.Write((short)1);w.Write((short)2);w.Write(rate);w.Write(rate*4);w.Write((short)4);w.Write((short)16);
   w.Write(System.Text.Encoding.ASCII.GetBytes("data"));w.Write(frames*4);
   for(int i=0;i<frames;i++){
    double t=(double)i/rate,local=t-.3-Math.Floor((t-.3)/.5)*.5;
    double envelope=t>=.3&&local<.14?Math.Min(1,local/.005)*Math.Exp(-local/.045):0;
    short x=(short)(32767*.12*envelope*Math.Sin(2*Math.PI*65*t));w.Write(x);w.Write(x);
   }
  }return bytes;
 }
}
'@
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $app 'runtime/music-audio.cs'))+[Environment]::NewLine+$helper)
$assertions=0
function Assert-That([bool]$Value,[string]$Message){if(!$Value){throw $Message};$script:assertions++}
$rows=@()
foreach($rate in @(44100,48000)){
 foreach($gain in @(.015,.12,.4)){
  foreach($opposite in @($false,$true)){
   $n=[GptMusicAudioProbe]::Signal($rate,2,65,$gain,$true,$opposite)
   Assert-That ($n-eq 6) ('Expected six bass onsets: '+$rate+'/'+$gain+'/'+$opposite+' got '+$n)
   $rows+=@{rate=$rate;gain=$gain;oppositeStereo=$opposite;beats=$n}
  }
 }
 Assert-That ([GptMusicAudioProbe]::Signal($rate,2,2000,.4,$true,$false)-eq 0) 'Treble pulses must not act as bass drums'
 Assert-That ([GptMusicAudioProbe]::Signal($rate,2,65,.12,$false,$false)-le 1) 'Sustained bass must not repeatedly trigger'
 Assert-That ([GptMusicAudioProbe]::Signal($rate,2,65,0,$true,$false)-eq 0) 'Silence must not trigger'
}
Assert-That ([GptMusicCapture]::Decode([byte[]]@(0,128),0,1,16)-eq -1) 'PCM16 negative full scale'
Assert-That ([GptMusicCapture]::Decode([byte[]]@(0,0,128),0,1,24)-eq -1) 'PCM24 negative full scale'
Assert-That ([GptMusicCapture]::Decode([byte[]]@(0,0,0,128),0,1,32)-eq -1) 'PCM32 negative full scale'
Assert-That ([GptMusicCapture]::Decode([BitConverter]::GetBytes([single]::NaN),0,3,32)-eq 0) 'Invalid float must be sanitized'
$liveResult=$null
if($Live){
 $capture=[GptMusicCapture]::new();$player=$null;$stream=$null
 try{
  $deadline=[DateTime]::UtcNow.AddSeconds(8)
  do{Start-Sleep -Milliseconds 100;$s=$capture.Snapshot()}while(!$s.Running -and [DateTime]::UtcNow-lt $deadline)
  Assert-That $s.Running ('Playback capture did not start: '+$s.Error)
  $before=$s.Sequence;$stream=[IO.MemoryStream]::new([GptMusicAudioProbe]::Wave(48000,$PlaybackSeconds));$player=[Media.SoundPlayer]::new($stream)
  $player.Load();$start=[GptMusicCapture]::NowMs;$player.Play();$lockedSamples=0;$lockedBpm=0.0;$tracked=0;$trace=@()
  do{Start-Sleep -Milliseconds 25;$s=$capture.Snapshot();$tracked=[Math]::Max($tracked,$s.BeatSequence)
    $trace+=@{t=([GptMusicCapture]::NowMs-$start)/1000;onsets=$s.Sequence;candidates=$s.Candidates;resets=$s.TempoResets;discontinuities=$s.Discontinuities;locked=$s.RhythmLocked;bpm=$s.Bpm}
    if($s.RhythmLocked){$lockedSamples++;$lockedBpm=$s.Bpm}
  }while([GptMusicCapture]::NowMs-$start-lt $PlaybackSeconds*1000+200)
  $liveResult=@{running=$s.Running;sampleRate=$s.SampleRate;channels=$s.Channels;detectedBeats=($s.Sequence-$before);trackedBeats=$tracked;lockedSamples=$lockedSamples;lockedBpm=$lockedBpm;error=$s.Error}
  if($ResultFile){[IO.File]::WriteAllText(($ResultFile+'.trace.json'),(@{live=$liveResult;trace=$trace}|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
  Assert-That (($s.Sequence-$before)-ge 4) 'Real playback loopback did not observe the test bass onsets'
  if($PlaybackSeconds-ge 6){
   Assert-That ($tracked-ge 6 -and $lockedSamples-ge 80) 'Real playback did not establish and sustain a musical beat clock'
   Assert-That ([Math]::Abs($lockedBpm-120)-lt 3) 'Real playback tempo does not match the known 120 BPM rhythm'
  }
 }finally{if($player){$player.Dispose()};if($stream){$stream.Dispose()};$capture.Dispose()}
}
$result=@{passed=$true;assertions=$assertions;synthetic=$rows;live=$liveResult}
if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
Write-Output ('PASS: music audio '+$assertions+' checks');if($liveResult){$liveResult|ConvertTo-Json -Compress}
