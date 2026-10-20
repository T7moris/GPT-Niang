param([string]$ResultFile)
$ErrorActionPreference='Stop';$app=Split-Path $PSScriptRoot -Parent
$helper=@'
public sealed class MusicEnvelopeResult {public double ExpectedBpm,EstimatedBpm,PhaseError,StopDelay;public int LockedFrames,BassCycleFrames;public bool Stopped;}
public static class MusicEnvelopeProbe {
 public static MusicEnvelopeResult Run(double bpm){
  var c=new GptMusicTempoTracker();var r=new MusicEnvelopeResult{ExpectedBpm=bpm};double p=60/bpm,nextNoise=.2;int noise=0;
  for(int i=0;i<2400;i++){
   double t=i*.01,local=t-.3-Math.Floor((t-.3)/p)*p;
   double low=t>=.3&&t<20?.004*Math.Exp(-local/.075):0;
   // Discrete threshold crossings are polluted by a separate irregular bass
   // phrase. Only the repeating continuous bass envelope reveals the beat.
   double onset=0;if(t>=nextNoise&&t<20){onset=.85;noise++;nextNoise+=.18+((noise*37)%51)*.01;}
   c.ObserveEnvelope(t,low,low*1.8);c.Step(t,onset,low>.00012);
   if(c.Locked&&t>8&&t<20){r.LockedFrames++;r.EstimatedBpm=c.Bpm;if(c.UsesBassCycle)r.BassCycleFrames++;
    double nearest=.3+Math.Round((c.NextBeat-.3)/p)*p;r.PhaseError=Math.Max(r.PhaseError,Math.Abs(c.NextBeat-nearest));}
   if(c.Locked&&t>=20)r.StopDelay=t-20;
  }
  r.Stopped=!c.Locked;return r;
 }
 public static bool Nonperiodic(){
  var c=new GptMusicTempoTracker();double[] times={.30,.49,1.13,1.36,2.07,2.48,3.31,3.54,4.17,4.42,5.24,5.61,6.36,6.63};int n=0;double last=-10;
  for(int i=0;i<1000;i++){double t=i*.01,onset=0;if(n<times.Length&&t>=times[n]){last=t;onset=1;n++;}
   double low=.004*Math.Exp(-(t-last)/.06);c.ObserveEnvelope(t,low,low*1.8);c.Step(t,onset,low>.00012);if(c.Locked)return false;}
  return true;
 }
 public static bool FillDoesNotPause(){
  var c=new GptMusicTempoTracker();double p=.5,next=.3;
  for(int i=0;i<1400;i++){
   double t=i*.01,onset=0;bool fill=t>=6&&t<7.5;
   if(t>=next){if(!fill&&t<11)onset=1;next+=p;}
   double local=fill?(t-6.17-Math.Floor((t-6.17)/.25)*.25):(t-.3-Math.Floor((t-.3)/p)*p);
   double low=t>=.3&&t<11?.004*Math.Exp(-local/.075):0;
   c.ObserveEnvelope(t,low,low*1.8);c.Step(t,onset,low>.00012);
   if(t>=6&&t<8&&(!c.Locked||Math.Abs(c.Bpm-120)>2))return false;
   if(t>12.3&&c.Locked)return false;
  }
  return true;
 }
}
'@
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $app 'runtime/music-audio.cs'))+[Environment]::NewLine+$helper)
$rows=@()
foreach($bpm in @(90,120,170)){
 $r=[MusicEnvelopeProbe]::Run($bpm);$rows+=$r
 if($r.BassCycleFrames-lt 350 -or [Math]::Abs($r.EstimatedBpm-$bpm)-gt 3 -or $r.PhaseError-gt .055 -or $r.StopDelay-gt 1.25 -or !$r.Stopped){throw ('Bass envelope failed: '+($r|ConvertTo-Json -Compress))}
}
if(![MusicEnvelopeProbe]::Nonperiodic()){throw 'Irregular bass sounds falsely acquired a repeating rhythm'}
if(![MusicEnvelopeProbe]::FillDoesNotPause()){throw 'Short audible drum fill paused the known beat, or silence failed to stop it'}
$result=@{passed=$true;scenarios=$rows;irregularBassIgnored=$true;silenceStopsClock=$true;shortFillKeepsTempo=$true}
if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))}
Write-Output 'PASS: bass envelope recovers tempo/phase despite irregular threshold crossings; silence and irregular bass stop safely'
