param([string]$ResultFile,[string]$AppDirectory=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$helper=@'
public sealed class TempoRecheckResult {
 public double ExpectedBpm,Gain,Origin,FirstLock,FirstCorrectLock,LastBpm,MaxPhaseError;
 public int LockedFrames,WrongFrames;public bool SilenceStopped;
}
public static class TempoRecheckProbe {
 public static TempoRecheckResult Stable(double bpm,double gain,double origin){
  var c=new GptMusicTempoTracker();var r=new TempoRecheckResult{ExpectedBpm=bpm,Gain=gain,Origin=origin,FirstLock=-1,FirstCorrectLock=-1};
  double p=60/bpm,nextNoise=.2;int noise=0;
  for(int i=0;i<1900;i++){
   double t=i*.01,local=t-origin-System.Math.Floor((t-origin)/p)*p;
   double low=t>=origin&&t<16?.004*gain*System.Math.Exp(-local/.075):0;
   double onset=0;if(t>=nextNoise&&t<16){onset=.85;noise++;nextNoise+=.18+((noise*37)%51)*.01;}
   c.ObserveEnvelope(t,low,low*1.8);c.Step(t,onset,low>.00012);
   if(c.Locked&&r.FirstLock<0)r.FirstLock=t;
   if(c.Locked&&System.Math.Abs(c.Bpm-bpm)<3&&r.FirstCorrectLock<0)r.FirstCorrectLock=t;
   if(t>=6&&t<16){
    if(c.Locked){r.LockedFrames++;r.LastBpm=c.Bpm;double expected=origin+System.Math.Round((c.NextBeat-origin)/p)*p;r.MaxPhaseError=System.Math.Max(r.MaxPhaseError,System.Math.Abs(c.NextBeat-expected));if(System.Math.Abs(c.Bpm-bpm)>3)r.WrongFrames++;}
   }
  }
  r.SilenceStopped=!c.Locked;return r;
 }
 public static object Change(double before,double after){
  var c=new GptMusicTempoTracker();double nextNoise=.2,firstCorrect=-1,lastBpm=0;int noise=0,wrongAfterSettling=0;
  for(int i=0;i<2900;i++){
   double t=i*.01,p=60/(t<10?before:after),origin=t<10?.3:10.3;
   double local=t-origin-System.Math.Floor((t-origin)/p)*p;
   double low=t>=.3&&t<26?.004*System.Math.Exp(-local/.075):0;
   double onset=0;if(t>=nextNoise&&t<26){onset=.85;noise++;nextNoise+=.18+((noise*37)%51)*.01;}
   c.ObserveEnvelope(t,low,low*1.8);c.Step(t,onset,low>.00012);
   if(t>=10.3&&c.Locked&&System.Math.Abs(c.Bpm-after)<3&&firstCorrect<0)firstCorrect=t;
   if(t>=19&&t<26&&c.Locked){lastBpm=c.Bpm;if(System.Math.Abs(c.Bpm-after)>3)wrongAfterSettling++;}
  }
  return new {fromBpm=before,toBpm=after,firstCorrectAt=firstCorrect,adaptationSeconds=firstCorrect<0?-1:firstCorrect-10.3,lastBpm,wrongAfterSettling,silenceStopped=!c.Locked};
 }
}
'@
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $AppDirectory 'runtime/music-audio.cs'))+[Environment]::NewLine+$helper)
$rows=@()
foreach($bpm in @(90,120,170)){
 foreach($gain in @(.25,1,4)){
  foreach($origin in @(.30,.47)){
   $r=[TempoRecheckProbe]::Stable($bpm,$gain,$origin);$rows+=$r
   if($r.FirstCorrectLock-lt 0-or $r.FirstCorrectLock-$origin-gt 3.4-or $r.LockedFrames-lt 950-or $r.WrongFrames-gt 0-or $r.MaxPhaseError-gt .055-or !$r.SilenceStopped){throw ('Stable envelope acquisition failed: '+($r|ConvertTo-Json -Compress))}
  }
 }
}
$changes=@()
foreach($pair in @(@(90,120),@(120,160),@(170,90))){
 $r=[TempoRecheckProbe]::Change($pair[0],$pair[1]);$changes+=$r
 if($r.adaptationSeconds-lt 0-or $r.adaptationSeconds-gt 8-or $r.wrongAfterSettling-gt 0-or !$r.silenceStopped){throw ('Envelope did not correct tempo without a half-speed lock: '+($r|ConvertTo-Json -Compress))}
}
$result=@{passed=$true;stableCases=$rows;tempoChanges=$changes;irregularOnsetInterference=$true;halfSpeedRejected=$true;silenceStopsClock=$true}
if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
Write-Output ('PASS: '+$rows.Count+' tempo/gain/start-offset cases; '+$changes.Count+' envelope tempo changes; no half-speed lock after settling')
