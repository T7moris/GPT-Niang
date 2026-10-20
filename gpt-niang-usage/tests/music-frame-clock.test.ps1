param([string]$ResultFile,[string]$AppDirectory=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$script:appDir=$AppDirectory
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml,System.Windows.Forms,System.Drawing
$helper=@'
public sealed class MusicFrameClockResult {public double Bpm,Fps,Dpi,GapMs,MaxPhaseErrorMs;}
public static class MusicFrameClockProbe {
 public static MusicFrameClockResult Run(double bpm,double fps,double dpi,double gap){
  var m=new GptMusicMotion(600*dpi,650*dpi,1200*dpi,650*dpi,132*dpi,dpi);m.Phase=2;m.Props=1;
  var method=typeof(GptMusicMotion).GetMethod("Step",new System.Type[]{typeof(double),typeof(bool),typeof(bool),typeof(double),typeof(double),typeof(double),typeof(double)});
  var r=new MusicFrameClockResult{Bpm=bpm,Fps=fps,Dpi=dpi,GapMs=gap*1000};
  double now=0,p=60/bpm;bool stalled=false;
  while(now<5){
   double elapsed=1/fps;if(!stalled&&now>=2){elapsed=gap;stalled=true;}now+=elapsed;
   double phase=(now/p)%1,dt=System.Math.Min(.12,elapsed);
   if(method!=null)method.Invoke(m,new object[]{dt,false,true,phase,p,1.0,elapsed});
   else m.Step(dt,false,true,phase,p,1);
   if(stalled){double e=m.Cycle-phase;e-=System.Math.Round(e);r.MaxPhaseErrorMs=System.Math.Max(r.MaxPhaseErrorMs,System.Math.Abs(e)*p*1000);}
  }
  return r;
 }
}
'@
$audioText=[IO.File]::ReadAllText((Join-Path $script:appDir 'runtime/music-audio.cs'))
$visualText=[IO.File]::ReadAllText((Join-Path $script:appDir 'runtime/music-visual.cs'))
$visualText=[regex]::Replace($visualText,'(?m)^using [^;\r\n]+;\r?\n','')
$visualUsings='using System.Windows;using System.Windows.Controls;using System.Windows.Interop;using System.Windows.Media;using System.Windows.Media.Imaging;using System.Windows.Threading;'
$refs=@('System.dll','System.Core.dll','System.Xaml.dll','System.Windows.Forms.dll','System.Drawing.dll',[Windows.Window].Assembly.Location,[Windows.Media.Brush].Assembly.Location,[Windows.Point].Assembly.Location)
Add-Type -TypeDefinition ($visualUsings+[Environment]::NewLine+$audioText+[Environment]::NewLine+$visualText+[Environment]::NewLine+$helper) -ReferencedAssemblies $refs
$rows=@()
foreach($bpm in @(90,120,170)){
 foreach($fps in @(30,60,144)){
  foreach($dpi in @(1,1.5,2)){
   foreach($gap in @(.14,.21,.35,.50,1.0,2.25)){
    $r=[MusicFrameClockProbe]::Run($bpm,$fps,$dpi,$gap);$rows+=$r
    if($r.MaxPhaseErrorMs-gt .001){throw ('A rendering stall left the musical clock behind: '+($r|ConvertTo-Json -Compress))}
   }
  }
 }
}
$motion=[GptMusicMotion]::new(600,650,1200,650,132,1);$motion.Phase=2;$motion.Props=1
$motion.Step(.02,$false,$true,.2,.5,1,2.0)
$time=$motion.Time;$x=$motion.X
$motion.Step(.12,$true,$true,.6,.5,1,3.0)
if($motion.Time-ne $time-or $motion.X-ne $x){throw 'Clock catch-up consumed paused physics time'}
$motion.Step(.02,$false,$true,.8,.5,1,.02)
$phaseError=$motion.Cycle-.8;$phaseError-=[Math]::Round($phaseError)
if([Math]::Abs($phaseError)-gt 1e-9){throw 'Resume used stale musical time'}
$result=@{passed=$true;cases=$rows.Count;maxPhaseErrorMs=($rows|Measure-Object MaxPhaseErrorMs -Maximum).Maximum;pausedPhysicsPreserved=$true;resumeUsesCurrentPhase=$true;scenarios=$rows}
if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
Write-Output ('PASS: '+$rows.Count+' combinations of tempo, render rate, DPI and frame stalls; no extra beat-phase lag; paused physics preserved')
