param([string]$ResultFile)
$ErrorActionPreference='Stop';$script:appDir=Split-Path $PSScriptRoot -Parent
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime/music.ps1'),[Text.Encoding]::UTF8)))
Initialize-WidgetMusicTypes
$rows=@();$failures=@();$minRetention=1.0;$minDistance=1e9
foreach($dpi in @(1.0,1.5,2.0)){
 foreach($dt in @((1.0/30),(1.0/60),(1.0/144))){
  foreach($gap in @(.005,.020,.040,.060)){
   $m=[GptMusicMotion]::new(600*$dpi,610*$dpi,5000*$dpi,650*$dpi,132*$dpi,$dpi);$m.Phase=2;$m.BeginHold(0,0)
   $elapsed=0.0
   while($elapsed-lt .18){$s=[Math]::Min($dt,.18-$elapsed);$elapsed+=$s;$m.SamplePointer(1000*$elapsed*$dpi,0,$s)}
   $speed=$m.ThrowX;$idle=0.0
   while($idle-lt $gap){$s=[Math]::Min($dt,$gap-$idle);$idle+=$s;$m.SamplePointer(180*$dpi,0,$s)}
   # MouseUp can arrive just after an animation frame with no extra movement.
   $m.SamplePointer(180*$dpi,0,.001);$m.Release();$retention=$m.Vx/$speed
   $origin=$m.X
   for($t=0;$t-lt 1;$t+=$dt){$m.Step($dt,$false,$true,($t/.5),.5,1)}
   $distance=($m.X-$origin)/$dpi;$minRetention=[Math]::Min($minRetention,$retention);$minDistance=[Math]::Min($minDistance,$distance)
   $rows+=@{dpi=$dpi;frameSeconds=$dt;releaseGapMs=$gap*1000;speedRetained=$retention;oneSecondTravelDip=$distance}
   if($retention-lt .85 -or $distance-lt 450){$failures+=$rows[-1]}
   $m.BeginHold(0,0)
   for($t=$dt;$t-lt .2;$t+=$dt){$m.SamplePointer(1000*$t*$dpi,0,$dt)}
   for($t=0;$t-lt .35;$t+=$dt){$m.SamplePointer(190*$dpi,0,$dt)}
   $m.Release()
   if([Math]::Abs($m.Vx)-gt 2*$dpi){throw 'Deliberately holding still retained unwanted sideways momentum'}
  }
 }
}
$r=@{passed=($failures.Count-eq 0);cases=$rows.Count;failures=$failures;scenarios=$rows;minSpeedRetention=$minRetention;minOneSecondTravelDip=$minDistance;deliberateStationaryHoldClearsMomentum=$true}
if($ResultFile){[IO.File]::WriteAllText($ResultFile,($r|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))}
if($failures.Count){throw ('Quick-flick release failed in '+$failures.Count+'/'+$rows.Count+' cases; minimum retained speed '+$minRetention.ToString('P1')+', minimum one-second travel '+[Math]::Round($minDistance)+' DIP')}
Write-Output ('PASS: '+$rows.Count+' quick-flick release cases, 5-60 ms button delay, sustained glide and deliberate hold clears momentum')
