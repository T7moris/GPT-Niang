param([switch]$Live,[string]$ResultFile)
$ErrorActionPreference='Stop';$app=Split-Path $PSScriptRoot -Parent
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $app 'runtime/music-audio.cs')))
$supported=[Environment]::OSVersion.Version.Build-ge 20348;$capture=$null;$liveResult=$null;$quiet=$null
$selectionCases=@()
Add-Type -TypeDefinition @'
using System;using System.Diagnostics;using System.Reflection;using System.Runtime.Serialization;using System.Collections.Generic;
public sealed class EmptyMediaSession {public object GetCurrentSession(){return null;}}
public static class CachedMusicSourceProbe {
 static BindingFlags F=BindingFlags.Instance|BindingFlags.NonPublic;
 static void Set(object o,string key,object value){o.GetType().GetField(key,F).SetValue(o,value);}
 public static object Run(Type capture){
  object owner=FormatterServices.GetUninitializedObject(capture);
  var sourceField=capture.GetField("source",F);var source=Activator.CreateInstance(sourceField.FieldType,true);
  Set(source,"managerType",typeof(EmptyMediaSession));Set(source,"sessionType",typeof(EmptyMediaSession));Set(source,"manager",new EmptyMediaSession());
  Set(owner,"source",source);Set(owner,"autoMusic",true);
  var choose=capture.GetMethod("ChooseProcess",F);var rows=new List<object>();uint live;long creation;
  using(var process=Process.GetCurrentProcess()){live=(uint)process.Id;creation=process.StartTime.ToUniversalTime().Ticks;}
  uint[] pids={0,live,Int32.MaxValue,live};long[] times={0,creation,creation,creation-1};
  string[] names={"no cached player","live or paused player preserved","exited player falls back","reused PID falls back"};
  for(int i=0;i<pids.Length;i++){
   Set(owner,"selectedProcess",pids[i]);Set(owner,"selectedCreation",times[i]);uint actual=(uint)choose.Invoke(owner,null),expected=i==1?live:0;
   rows.Add(new{name=names[i],actual,expected,passed=actual==expected});
  }
  return rows;
 }
}
'@
if($supported){
 $selectionCases=@([CachedMusicSourceProbe]::Run([GptMusicCapture]))
 if(@($selectionCases|Where-Object {!$_.passed}).Count){throw 'Cached music player liveness regression'}

 try{
  $capture=[GptMusicCapture]::new([uint32]$PID);$sw=[Diagnostics.Stopwatch]::StartNew();$peak=0.0;$snap=$null
  while($sw.Elapsed.TotalMilliseconds-lt 4000){Start-Sleep -Milliseconds 10;$snap=$capture.Snapshot();$peak=[Math]::Max($peak,$snap.Level);if($snap.Running -and $snap.FirstPacketMs-gt 0){break}}
  if(!$snap.Running-or $snap.SourceProcessId-ne $PID-or $snap.SampleRate-ne 48000-or $snap.Channels-ne 2-or $peak-gt .000001-or $snap.RhythmLocked){throw ('Silent process capture included another application: '+($snap|ConvertTo-Json -Compress))}
  $quiet=@{sourceProcessId=$snap.SourceProcessId;peak=$peak;captureReadyMs=$snap.CaptureReadyMs;firstPacketMs=$snap.FirstPacketMs}
 }finally{if($capture){$capture.Dispose();$capture=$null}}
}
$sw=[Diagnostics.Stopwatch]::StartNew();$capture=[GptMusicCapture]::new($true);$capture.Dispose();$cancelMs=$sw.Elapsed.TotalMilliseconds
if($cancelMs-gt 400){throw ('Stopping startup capture blocked: '+$cancelMs+' ms')}
if($Live-and $supported){
 $work=Join-Path ([IO.Path]::GetTempPath()) ('GptNiangMusic-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $work
 $readyFile=Join-Path $work 'player.json';$helper=Join-Path $PSScriptRoot 'music-player-probe.ps1'
 $child=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$helper+'"'),'-ReadyFile',('"'+$readyFile+'"')) -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $work 'player-error.log')
 $clock=[Diagnostics.Stopwatch]::StartNew();$trace=New-Object 'Collections.Generic.List[object]';$playAt=0.0;$beforePeak=0.0;$firstOnset=0.0;$lockedBpm=@();$last=$null
 try{
  $capture=[GptMusicCapture]::new([uint32]$child.Id)
  while($clock.Elapsed.TotalSeconds-lt 11.8){
   Start-Sleep -Milliseconds 10;$last=$capture.Snapshot();$now=[GptMusicCapture]::NowMs
   if(Test-Path -LiteralPath $readyFile){try{$r=Get-Content -LiteralPath $readyFile -Raw|ConvertFrom-Json;if($r.playAt-gt 0){$playAt=[double]$r.playAt}}catch{}}
   if($playAt-eq 0){$beforePeak=[Math]::Max($beforePeak,$last.Level)}
   if($last.Sequence-gt 0-and $firstOnset-eq 0){$firstOnset=$now}
   if($playAt-gt 0-and $now-$playAt-ge 3000-and $now-$playAt-lt 7500-and $last.RhythmLocked){$lockedBpm+=$last.Bpm}
   $trace.Add([pscustomobject]@{now=$now;level=$last.Level;onsets=$last.Sequence;locked=$last.RhythmLocked;bpm=$last.Bpm;source=$last.SourceProcessId;error=$last.Error})
  }
  $liveResult=@{childPid=$child.Id;sourceProcessId=$last.SourceProcessId;captureReadyMs=$last.CaptureReadyMs;firstPacketMs=$last.FirstPacketMs;quietBeforeTone=$beforePeak;onsets=$last.Sequence;expectedOnsets=16;firstOnsetAfterScheduledBeatMs=$firstOnset-$playAt-300;lockedSamples=$lockedBpm.Count;bpm=$lockedBpm|Measure-Object -Minimum -Maximum -Average;silenceStopped=(!$last.RhythmLocked);error=$last.Error}
  if($ResultFile){[IO.File]::WriteAllText(($ResultFile+'.trace.json'),(@{result=$liveResult;trace=$trace.ToArray()}|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))}
  if($playAt-eq 0-or $beforePeak-gt .000001-or $last.Sequence-ne 16-or $last.SourceProcessId-ne $child.Id-or $lockedBpm.Count-lt 100-or ($lockedBpm|Where-Object{[Math]::Abs($_-120)-gt 3})-or $last.RhythmLocked-or $last.Error){throw ('Isolated live 120 BPM capture failed: '+($liveResult|ConvertTo-Json -Depth 5 -Compress))}
 }finally{if($capture){$capture.Dispose();$capture=$null};$null=$child.WaitForExit(2500)}
}
$result=@{passed=$true;supported=$supported;quietProcess=$quiet;startupCancelMs=$cancelMs;cachedPlayerSelection=$selectionCases;live=$liveResult;audioSamplesStored=$false}
if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
if($supported){Write-Output 'PASS: native process isolation and cancellable startup'}else{Write-Output 'SKIP: process isolation capture requires Windows build 20348 or newer; endpoint startup cancellation was still checked'};if($liveResult){$liveResult|ConvertTo-Json -Depth 5}
