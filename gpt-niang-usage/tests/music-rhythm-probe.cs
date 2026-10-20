using System;
using System.Collections.Generic;
public sealed class MusicRhythmResult {
 public double Bpm,Gain,MaxDelay,MinDrive,MaxDrive,MaxCompression,MinCompression,MaxFrameChange;
 public double EstimatedBpm,MaxBeatPhaseError,MaxPosePhaseError;public int LockedFrames;public int Expected,Detected,Missed,Extra;public bool Grounded=true,Settled;
}
public static class MusicRhythmProbe {
 public static MusicRhythmResult Run(int rate,double bpm,double gain) {
  var r=new MusicRhythmResult{Bpm=bpm,Gain=gain,MinDrive=1};
  var d=new GptMusicBeatDetector(rate,2);var row=new double[2];
  var m=new GptMusicMotion(600,650,1200,650,132,1);m.Phase=2;m.Props=1;
  var onsets=new List<double>();var hits=new List<double>();
  double interval=60/bpm,duration=.3+interval*16;long seen=0;double beat=0,oldBend=0,oldDelta=0;
  for(int k=0;k<16;k++)onsets.Add(.3+k*interval);
  for(int i=0;i<(duration+2)*rate;i++){
   double t=(double)i/rate,k=Math.Floor((t-.3)/interval),local=t-.3-k*interval;
   bool active=t>=.3&&k<16;
   double accent=k%4==0?1:k%4==2?.75:.50;
   double kick=active?accent*Math.Min(1,local/.004)*Math.Exp(-local/.052)*Math.Sin(2*Math.PI*(58*local+1.9*(1-Math.Exp(-local*30)))):0;
   double bass=active?.085*Math.Sin(2*Math.PI*(k%2==0?110:146.83)*t)*Math.Min(1,local/.03):0;
   double hat=active?.05*Math.Exp(-(local%(interval/2))/.015)*Math.Sin(2*Math.PI*2300*t):0;
   row[0]=gain*(kick+bass+hat);row[1]=gain*(kick+bass-hat);d.Push(row);
   if(d.Sequence!=seen){seen=d.Sequence;hits.Add(t);beat=d.Strength;}
   if(i%(rate/60)==0){
    var clock=d.Tempo;
    double phase=clock.Locked?1+(t-clock.NextBeat)/clock.Period:0;
    m.Step(1.0/60,false,clock.Locked,phase,clock.Period,1);beat=0;
    if(clock.Locked&&t>3&&t<duration){r.LockedFrames++;r.EstimatedBpm=clock.Bpm;
     double nearest=.3+Math.Round((clock.NextBeat-.3)/interval)*interval;
     r.MaxBeatPhaseError=Math.Max(r.MaxBeatPhaseError,Math.Abs(clock.NextBeat-nearest));}
    r.MaxCompression=Math.Max(r.MaxCompression,m.Bend);r.MinCompression=Math.Min(r.MinCompression,m.Bend);
    double delta=m.Bend-oldBend;
    if(clock.Locked&&t>3&&t<duration&&oldDelta>0&&delta<=0&&oldBend>.25){
     double peakAt=t-1.0/60,expected=.3+Math.Round((peakAt-.3)/interval)*interval;
     r.MaxPosePhaseError=Math.Max(r.MaxPosePhaseError,Math.Abs(peakAt-expected));
    }
    r.MaxFrameChange=Math.Max(r.MaxFrameChange,Math.Abs(delta));oldDelta=delta;oldBend=m.Bend;
    if(t>1&&t<duration){r.MinDrive=Math.Min(r.MinDrive,d.Drive);r.MaxDrive=Math.Max(r.MaxDrive,d.Drive);}
    if(m.Y!=650)r.Grounded=false;
   }
  }
  r.Expected=onsets.Count;r.Detected=hits.Count;r.Settled=!m.Moving;
  var used=new HashSet<int>();
  foreach(double onset in onsets){int found=-1;for(int j=0;j<hits.Count;j++)if(!used.Contains(j)&&hits[j]>=onset&&hits[j]-onset<.10){found=j;break;}
   if(found<0)r.Missed++;else{used.Add(found);r.MaxDelay=Math.Max(r.MaxDelay,hits[found]-onset);}}
  r.Extra=hits.Count-used.Count;return r;
 }
}