param([string]$ResultFile)
$ErrorActionPreference='Stop';$app=Split-Path $PSScriptRoot -Parent
$helper=@'
public static class MusicQuietStartupProbe {
 public static object Run(int rate,double bpm,double gain,double start){
  var d=new GptMusicBeatDetector(rate,2);var row=new double[2];double period=60/bpm,first=-1,firstLock=-1;long sequence=0;
  for(int i=0;i<rate*6;i++){
   double t=i/(double)rate,local=t-start-Math.Floor((t-start)/period)*period;
   double kick=t>=start?gain*Math.Min(1,local/.004)*Math.Exp(-local/.052)*Math.Sin(2*Math.PI*(58*local+1.9*(1-Math.Exp(-local*30)))):0;
   row[0]=row[1]=kick;d.Push(row);
   if(d.Sequence!=sequence){sequence=d.Sequence;if(first<0)first=t;}
   if(d.Tempo.Locked&&firstLock<0)firstLock=t;
  }
  return new {rate,bpm,gain,start,onsets=sequence,expectedOnsets=(int)Math.Ceiling((6-start)/period),firstOnsetMs=first<0?-1:(first-start)*1000,firstLockSeconds=firstLock,finalBpm=d.Tempo.Bpm};
 }
 public static object Negative(int kind,double gain){
  var d=new GptMusicBeatDetector(48000,2);var row=new double[2];int locked=0;uint seed=17;
  for(int i=0;i<48000*8;i++){
   double t=i/48000.0,local=t-.3-Math.Floor((t-.3)/.5)*.5;seed=1664525*seed+1013904223;
   double x=kind==0?0:kind==1?gain*Math.Sin(2*Math.PI*65*t):kind==2?(t>=.3?gain*Math.Exp(-local/.025)*Math.Sin(2*Math.PI*2000*t):0):(((seed>>8)/16777216.0)*2-1)*gain;
   row[0]=row[1]=x;d.Push(row);if(i%480==0&&d.Tempo.Locked)locked++;
  }
  return new {kind,gain,onsets=d.Sequence,lockedFrames=locked};
 }
 public static object VolumeChange(){
  var d=new GptMusicBeatDetector(48000,2);var row=new double[2];double firstQuiet=-1;long before=0;int misses=0;
  for(int i=0;i<48000*12;i++){
   double t=i/48000.0,local=t-.3-Math.Floor((t-.3)/.5)*.5,gain=t<4?.12:(t<8?.00015:.12);
   double x=t>=.3?gain*Math.Min(1,local/.004)*Math.Exp(-local/.052)*Math.Sin(2*Math.PI*65*t):0;row[0]=row[1]=x;
   before=d.Sequence;d.Push(row);if(t>4.3&&t<8&&d.Sequence>before&&firstQuiet<0)firstQuiet=t;
   if(t>=5&&t<8&&i%480==0&&!d.Tempo.Locked)misses++;
  }
  return new {firstQuietOnsetMs=firstQuiet<0?-1:(firstQuiet-4.3)*1000,quietUnlockedFrames=misses,finalBpm=d.Tempo.Bpm};
 }
}
'@
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $app 'runtime/music-audio.cs'))+[Environment]::NewLine+$helper)
$rows=@(foreach($rate in @(44100,48000)){foreach($bpm in @(90,120,170)){foreach($gain in @(.000015,.00005,.00015,.0005,.0015,.015,.12)){foreach($start in @(0,.3)){[MusicQuietStartupProbe]::Run($rate,$bpm,$gain,$start)}}}})
$negative=@(foreach($gain in @(.000015,.00015,.12)){foreach($kind in @(0,1,2)){[MusicQuietStartupProbe]::Negative($kind,$gain)}};[MusicQuietStartupProbe]::Negative(3,.00000001))
$change=[MusicQuietStartupProbe]::VolumeChange()
$failures=@()
foreach($r in $rows){if($r.firstOnsetMs-lt 0-or $r.firstOnsetMs-gt 60-or $r.onsets-ne $r.expectedOnsets-or [Math]::Abs($r.finalBpm-$r.bpm)-gt 2){$failures+=('Quiet onset or tempo failed: '+($r|ConvertTo-Json -Compress))}}
foreach($r in $negative){if($r.lockedFrames-gt 0-or ($r.kind-ne 1-and $r.onsets-ne 0)-or ($r.kind-eq 1-and $r.onsets-gt 1)){$failures+=('Non-rhythmic signal triggered: '+($r|ConvertTo-Json -Compress))}}
if($change.firstQuietOnsetMs-lt 0-or $change.firstQuietOnsetMs-gt 60-or $change.quietUnlockedFrames-gt 0-or [Math]::Abs($change.finalBpm-120)-gt 2){$failures+=('Volume change delayed detection: '+($change|ConvertTo-Json -Compress))}
$result=@{passed=($failures.Count-eq 0);scenarios=$rows;negativeSignals=$negative;volumeChange=$change;failures=$failures;latencyScope='Synthetic bass onset through audio detector; excludes fall, capture, display and physical sound latency'}
if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
if($failures.Count){throw ($failures-join [Environment]::NewLine)}
Write-Output ('Quiet-startup scenarios='+$rows.Count+'; failures='+$failures.Count+'; passed='+$result.passed)
