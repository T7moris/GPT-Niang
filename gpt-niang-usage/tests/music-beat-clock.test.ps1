param([string]$ResultFile)
$ErrorActionPreference='Stop'
$app=Split-Path $PSScriptRoot -Parent
$helper=@'
public sealed class MusicClockResult {public double ExpectedBpm,Bpm,MaxPhaseError;public int OffGridEvents,Beats;public bool Locked,QuietStopped,IsolatedSoundsIgnored;}
public static class MusicClockProbe {
 public static MusicClockResult Run(double bpm){
  var r=new MusicClockResult{ExpectedBpm=bpm};var c=new GptMusicTempoTracker();double p=60/bpm;int main=0,noise=0;
  for(int i=0;i<1400;i++){
   double t=i*.01,onset=0;
   if(t>=.3+main*p&&main<18){onset=main%2==0?.98:.86;main++;}
   if(t>=.3+noise*p+p*.29&&noise<18){onset=.65;noise++;r.OffGridEvents++;}
   bool active=t<.3+18*p;c.Step(t,onset,active);
   if(c.Locked&&t>3&&active){
    r.Locked=true;r.Bpm=c.Bpm;
    double expected=.3+Math.Round((c.NextBeat-.3)/p)*p;
    r.MaxPhaseError=System.Math.Max(r.MaxPhaseError,System.Math.Abs(expected-c.NextBeat));
   }
   if(t>.3+18*p+.3&&!c.Locked)r.QuietStopped=true;
  }
  r.Beats=(int)c.Sequence;
  var speech=new GptMusicTempoTracker();double[] isolated={.30,.49,1.13,1.36,2.07,2.48,3.31,3.54,4.17,4.42,5.24,5.61,6.36,6.63};int n=0;bool any=false;
  for(int i=0;i<800;i++){double t=i*.01,onset=0;if(n<isolated.Length&&t>=isolated[n]){onset=1;n++;}speech.Step(t,onset,true);any|=speech.Locked;}
  r.IsolatedSoundsIgnored=!any;return r;
 }
 public static bool TempoChange(){
  var c=new GptMusicTempoTracker();double next=.3;bool adapted=false;
  for(int i=0;i<1600;i++){double t=i*.01,onset=0;if(t>=next){onset=1;next+=t<6?.5:.375;}
   c.Step(t,onset,true);if(t>12&&c.Locked&&System.Math.Abs(c.Bpm-160)<3)adapted=true;}
  return adapted;
 }
 public static bool StopsAfterDrums(){
  var c=new GptMusicTempoTracker();double next=.3;
  for(int i=0;i<800;i++){double t=i*.01,onset=0;if(t>=next&&t<4.5){onset=1;next+=.5;}c.Step(t,onset,true);if(t>5.4&&c.Locked)return false;}
  return true;
 }
 public static bool QuietGaps(double bpm){
  var c=new GptMusicTempoTracker();double p=60/bpm,next=.3,last=-10;bool locked=false;
  for(int i=0;i<1000;i++){double t=i*.01,onset=0;if(t>=next&&t<8){onset=1;last=t;next+=p;}
   c.Step(t,onset,t-last<.12);if(t>3&&t<8&&c.Locked&&System.Math.Abs(c.Bpm-bpm)<2)locked=true;}
  return locked&&!c.Locked;
 }
}
'@
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $app 'runtime/music-audio.cs'))+[Environment]::NewLine+$helper)
$rows=@()
foreach($bpm in @(90,120,170)){
 $r=[MusicClockProbe]::Run($bpm);$rows+=$r
 if(!$r.Locked -or [Math]::Abs($r.Bpm-$bpm)-gt 2 -or $r.MaxPhaseError-gt .045 -or !$r.QuietStopped -or !$r.IsolatedSoundsIgnored){throw ('Beat clock failed: '+($r|ConvertTo-Json -Compress))}
 if(![MusicClockProbe]::QuietGaps($bpm)){throw 'Normal quiet gaps between drum hits erased the acquired beat clock'}
}
if(![MusicClockProbe]::TempoChange()){throw 'Abrupt song tempo change did not reacquire the new tempo'}
if(![MusicClockProbe]::StopsAfterDrums()){throw 'Clock kept inventing beats after percussion stopped'}
$result=@{passed=$true;scenarios=$rows;tempoChange=$true;noFreeRunningAfterDrums=$true;irregularLoudSoundsIgnored=$true}
if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
Write-Output 'PASS: tempo/phase tracking, off-grid interference, irregular sounds, silence, percussion stop and tempo changes'
