param([string]$ResultFile)
$ErrorActionPreference='Stop';$app=Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml,System.Windows.Forms,System.Drawing
$refs=@('System.dll','System.Core.dll','System.Xaml.dll','System.Windows.Forms.dll','System.Drawing.dll',[Windows.Window].Assembly.Location,[Windows.Media.Brush].Assembly.Location,[Windows.Point].Assembly.Location)
$helper=@'
public static class MusicStartupProbe {
 public static object Run(int rate,double bpm,double gain,int fps){
  var d=new GptMusicBeatDetector(rate,2);var m=new GptMusicMotion(600,650,1200,650,132,1);m.Phase=2;m.Props=1;
  var row=new double[2];double p=60/bpm,nextFrame=0,lastFrame=0,first=-1,firstLock=-1,lastOnset=-10;long sequence=0;bool reactedBeforeLock=false;
  for(int i=0;i<rate*5;i++){
   double t=(double)i/rate,k=Math.Floor((t-.3)/p),local=t-.3-k*p;
   double kick=t>=.3?gain*Math.Min(1,local/.004)*Math.Exp(-local/.052)*Math.Sin(2*Math.PI*(58*local+1.9*(1-Math.Exp(-local*30)))):0;
   row[0]=row[1]=kick;d.Push(row);if(d.Sequence!=sequence){sequence=d.Sequence;lastOnset=t;}
   if(d.Tempo.Locked&&firstLock<0)firstLock=t;
   if(t>=nextFrame){
    double dt=t-lastFrame;lastFrame=t;nextFrame+=1.0/fps;bool locked=d.Tempo.Locked;double phase=locked?1+(t-d.Tempo.NextBeat)/d.Tempo.Period:0;
    m.Step(dt,false,locked,phase,d.Tempo.Period,1,dt);if(!locked&&sequence>0)m.RespondToOnset(t-lastOnset,d.Strength);
    if(first<0&&m.Bend>.24){first=t;reactedBeforeLock=!locked;}
   }
  }
  return new {rate,bpm,gain,fps,firstResponseMs=(first-.3)*1000,firstLockSeconds=firstLock,reactedBeforeLock};
 }
 public static object NoBassClock(int kind){
  var d=new GptMusicBeatDetector(48000,2);var row=new double[2];int locked=0;
  for(int i=0;i<48000*12;i++){
   double t=i/48000.0,local=t-.3-Math.Floor((t-.3)/(.3333333333))*.3333333333;
   double bass=kind==0?0:.12*Math.Sin(2*Math.PI*65*t),hat=kind==1?0:(t>=.3?.10*Math.Exp(-local/.025)*Math.Sin(2*Math.PI*2000*t):0);
   row[0]=row[1]=bass+hat;d.Push(row);if(i%480==0&&t>3&&d.Tempo.Locked)locked++;
  }
  return new {kind,onsets=d.Sequence,lockedFrames=locked};
 }
 public static bool Interaction(){
  var m=new GptMusicMotion(600,650,1200,650,132,1);m.Bend=.07;m.RespondToOnset(0,1);if(m.Bend!=.07)return false;
  m.Phase=2;m.BeginHold();m.Bend=-.045;m.RespondToOnset(0,1);if(m.Bend!=-.045)return false;
  m.Release();m.Phase=2;m.RespondToOnset(.8,1);if(m.Bend!=-.045)return false;
  m.RespondToOnset(0,1);if(m.Bend<.39)return false;m.RespondToOnset(.16,1);return m.Bend<-.15;
 }
}
'@
$visual=[IO.File]::ReadAllText((Join-Path $app 'runtime/music-visual.cs'));$visual=[regex]::Replace($visual,'(?m)^using [^;\r\n]+;\r?\n','')
$using='using System.Windows;using System.Windows.Controls;using System.Windows.Interop;using System.Windows.Media;using System.Windows.Media.Imaging;using System.Windows.Threading;'
Add-Type -TypeDefinition ($using+[Environment]::NewLine+[IO.File]::ReadAllText((Join-Path $app 'runtime/music-audio.cs'))+[Environment]::NewLine+$visual+[Environment]::NewLine+$helper) -ReferencedAssemblies $refs
$rows=@(foreach($rate in @(44100,48000)){foreach($bpm in @(90,120,170)){foreach($gain in @(.015,.12)){foreach($fps in @(30,60,144)){[MusicStartupProbe]::Run($rate,$bpm,$gain,$fps)}}}})
foreach($r in $rows){if($r.firstResponseMs-lt 0-or $r.firstResponseMs-gt 60-or !$r.reactedBeforeLock){throw ('First bass onset waited for a tempo clock: '+($r|ConvertTo-Json -Compress))}}
$negative=@(0..2|ForEach-Object{[MusicStartupProbe]::NoBassClock($_)})
foreach($r in $negative){if($r.lockedFrames-ne 0){throw ('Treble or sustained bass acquired a false clock: '+($r|ConvertTo-Json -Compress))}}
if(![MusicStartupProbe]::Interaction()){throw 'Acquiring response disturbed flight/hold, or lost its elastic rebound'}
$result=@{passed=$true;scenarios=$rows;negativeSignals=$negative;interactionPreserved=$true;latencyScope='Synthetic audio through detector and simulated render frames; excludes physical output and panel latency'}
if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
Write-Output ('PASS: '+$rows.Count+' first-onset/frame-rate scenarios <=60 ms before tempo lock; treble and sustained bass rejected; flight and hold preserved')
