param([Parameter(Mandatory=$true)][string]$ReadyFile)
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;using System.IO;
public static class PlayerProbeTone {
 public static byte[] Wave(){
  int rate=48000,frames=rate*8;var bytes=new byte[44+frames*4];
  using(var stream=new MemoryStream(bytes))using(var w=new BinaryWriter(stream)){
   w.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));w.Write(bytes.Length-8);w.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt "));
   w.Write(16);w.Write((short)1);w.Write((short)2);w.Write(rate);w.Write(rate*4);w.Write((short)4);w.Write((short)16);w.Write(System.Text.Encoding.ASCII.GetBytes("data"));w.Write(frames*4);
   for(int i=0;i<frames;i++){double t=(double)i/rate,local=t-.3-Math.Floor((t-.3)/.5)*.5,env=t>=.3&&local<.14?Math.Min(1,local/.005)*Math.Exp(-local/.045):0;short x=(short)(32767*.12*env*Math.Sin(2*Math.PI*65*t));w.Write(x);w.Write(x);}
  }return bytes;
 }
 public static double Now {get{return System.Diagnostics.Stopwatch.GetTimestamp()*1000.0/System.Diagnostics.Stopwatch.Frequency;}}
}
'@
$stream=[IO.MemoryStream]::new([PlayerProbeTone]::Wave());$player=[Media.SoundPlayer]::new($stream)
try{
 $player.Load();@{pid=$PID;ready=$true;playAt=0}|ConvertTo-Json|Set-Content -LiteralPath $ReadyFile -Encoding UTF8
 Start-Sleep -Milliseconds 1200
 @{pid=$PID;ready=$true;playAt=[PlayerProbeTone]::Now}|ConvertTo-Json|Set-Content -LiteralPath $ReadyFile -Encoding UTF8
 $player.PlaySync()
}finally{$player.Dispose();$stream.Dispose()}
