param([string]$ResultFile)
$ErrorActionPreference='Stop'
$script:appDir=Split-Path $PSScriptRoot -Parent
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime/music.ps1'),[Text.Encoding]::UTF8)))
Initialize-WidgetMusicTypes
$rows=@();$checks=0;$max=0.0;$min=0.0
foreach($dpi in @(1.0,1.5,2.0)){
 foreach($step in @((1.0/30),(1.0/60),(1.0/144))){
  $motion=[GptMusicMotion]::new(350*$dpi,188*$dpi,800*$dpi,650*$dpi,132*$dpi,$dpi)
  $next=0.0;$beats=0
  for($t=0;$t-lt 12;$t+=$step){
   $locked=$motion.Phase-eq 2 -and $t-lt 8
   $motion.Step($step,$false,$locked,($t/.5),.5,1)
   if($motion.Y-gt $motion.Floor+.001){throw 'Character crossed the floor'}
   if($motion.Phase-eq 2 -and [Math]::Abs($motion.Y-$motion.Floor)-gt .001){throw 'Music beat lifted the feet'}
   if($motion.X-lt $motion.Margin-.001 -or $motion.X-gt $motion.Width-$motion.Margin+.001){throw 'Horizontal bounds failed'}
   $max=[Math]::Max($max,$motion.Bend);$min=[Math]::Min($min,$motion.Bend);$checks++
  }
  if($motion.Impacts-ne 3 -or $motion.Phase-ne 2){throw 'Expected the initial impact and exactly two diminishing rebounds'}
  if($motion.Moving){throw 'Animation did not settle after the last real onset'}
  if([Math]::Abs($motion.X-350*$dpi)-lt 1){throw 'Horizontal movement was lost'}
  $rows+=@{dpi=$dpi;step=$step;impacts=$motion.Impacts;finalX=$motion.X;stationary=$true}
 }
}
if([Math]::Abs([GptMusicMotion]::BeatPose(0)-.40)-gt 1e-9 -or [Math]::Abs([GptMusicMotion]::BeatPose(.32)+.16)-gt 1e-9){throw 'Exact beat compression or rebound pose changed'}
if($max-lt .32 -or $min-gt -.159){throw ('Requested stronger press/rebound missing in discrete frame samples: '+$max+'/'+$min)}
$motion=[GptMusicMotion]::new(350,188,800,650,132,1)
$motion.Phase=2;$motion.Y=650;$motion.Props=1;$motion.Step(.025,$false,$true,0,.5,1)
$x=$motion.X;$time=$motion.Time
for($i=0;$i-lt 120;$i++){$motion.Step(.025,$true,$true,0,.5,1)}
if($motion.X-ne $x -or $motion.Time-ne $time -or [Math]::Abs($motion.Bend)-gt .001){throw 'Interaction pause did not hold the character and settle pressure'}
$result=@{passed=$true;checks=$checks;cases=$rows;maxCompression=$max;minCompression=$min;interactionPause=$true}
if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
Write-Output ('PASS: music motion '+$checks+' samples; stronger press '+[Math]::Round($max,3)+' / rebound '+[Math]::Round($min,3))
