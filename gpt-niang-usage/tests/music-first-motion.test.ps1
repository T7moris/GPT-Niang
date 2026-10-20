param([string]$ResultFile)
$ErrorActionPreference='Stop';$app=Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml,System.Windows.Forms,System.Drawing
$references=@('System.dll','System.Core.dll','System.Xaml.dll','System.Windows.Forms.dll','System.Drawing.dll',[Windows.Window].Assembly.Location,[Windows.Media.Brush].Assembly.Location,[Windows.Point].Assembly.Location)
$helper=@'
public static class MusicFirstMotionProbe {
 public static object Run(int rate,double bpm,double gain,int fps,bool single){
  var d=new GptMusicBeatDetector(rate,2);var m=new GptMusicMotion(600,650,1200,650,132,1);m.Phase=2;m.Props=1;
  var row=new double[2];double period=60/bpm,nextFrame=0,lastFrame=0,lastOnset=-10,press=-1,movement=-1,pixel=-1,firstLock=-1;long sequence=0;bool beforeLock=false;
  for(int i=0;i<rate*6;i++){
   double t=i/(double)rate,local=t-.3-Math.Floor((t-.3)/period)*period;
   double x=t>=.3&&(!single||t<.3+period)?gain*Math.Min(1,local/.004)*Math.Exp(-local/.052)*Math.Sin(2*Math.PI*65*t):0;
   row[0]=row[1]=x;d.Push(row);if(d.Sequence!=sequence){sequence=d.Sequence;lastOnset=t;}
   if(d.Tempo.Locked&&firstLock<0)firstLock=t;
   if(t>=nextFrame){
    double dt=t-lastFrame;lastFrame=t;nextFrame+=1.0/fps;bool locked=d.Tempo.Locked;double phase=locked?1+(t-d.Tempo.NextBeat)/d.Tempo.Period:0;
    m.Step(dt,false,locked,phase,d.Tempo.Period,1,dt);if(!locked&&sequence>0)m.RespondToOnset(t-lastOnset,d.Strength);
    if(press<0&&m.Bend>.24)press=t;
    if(movement<0&&System.Math.Abs(m.X-600)>.001){movement=t;beforeLock=!locked;}
    if(pixel<0&&System.Math.Abs(m.X-600)>=.5)pixel=t;
   }
  }
  return new {rate,bpm,gain,fps,single,firstPressMs=(press-.3)*1000,firstMovementMs=(movement-.3)*1000,firstPixelMs=(pixel-.3)*1000,beforeLock,firstLock,settled=!m.Moving,clockLocked=d.Tempo.Locked};
 }
 public static bool Silence(){
  var m=new GptMusicMotion(600,650,1200,650,132,1);m.Phase=2;m.Props=1;
  for(int i=0;i<360;i++)m.Step(1.0/60,false,false,0,0,0);
  return m.X==600&&!m.Moving;
 }
}
'@
$visual=[IO.File]::ReadAllText((Join-Path $app 'runtime/music-visual.cs'));$visual=[regex]::Replace($visual,'(?m)^using [^;\r\n]+;\r?\n','')
$using='using System.Windows;using System.Windows.Controls;using System.Windows.Interop;using System.Windows.Media;using System.Windows.Media.Imaging;using System.Windows.Threading;'
Add-Type -TypeDefinition ($using+[Environment]::NewLine+[IO.File]::ReadAllText((Join-Path $app 'runtime/music-audio.cs'))+[Environment]::NewLine+$visual+[Environment]::NewLine+$helper) -ReferencedAssemblies $references
$rows=@(foreach($rate in @(44100,48000)){foreach($bpm in @(90,120,170)){foreach($gain in @(.00015,.12)){foreach($fps in @(30,60,144)){[MusicFirstMotionProbe]::Run($rate,$bpm,$gain,$fps,$false)}}}})
$single=@(foreach($fps in @(30,60,144)){[MusicFirstMotionProbe]::Run(48000,120,.00015,$fps,$true)})
foreach($r in @($rows)+@($single)){if(!$r.beforeLock-or $r.firstPressMs-lt 0-or $r.firstPressMs-gt 60-or $r.firstMovementMs-lt 0-or $r.firstMovementMs-gt 80-or $r.firstPixelMs-lt 0-or $r.firstPixelMs-gt 200){throw ('Full motion still waits for tempo: '+($r|ConvertTo-Json -Compress))}}
foreach($r in $single){if($r.clockLocked-or !$r.settled){throw 'A single real hit invented a continuing dance clock'}}
if(![MusicFirstMotionProbe]::Silence()){throw 'Grounded character moved without audio evidence'}
$result=@{passed=$true;scenarios=$rows;singleOnset=$single;silenceDoesNotMove=$true;latencyScope='Generated bass through detector and actual motion model at simulated frame rates; capture, physical output, display and initial fall excluded'}
if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
Write-Output ('PASS: '+$rows.Count+' full-motion starts before tempo lock; single hits settle; silence stays still')
