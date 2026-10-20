param([string]$ResultFile)
$ErrorActionPreference='Stop'
$script:appDir=Split-Path $PSScriptRoot -Parent
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime/music.ps1'),[Text.Encoding]::UTF8)))
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml,System.Windows.Forms,System.Drawing
$refs=@('System.dll','System.Core.dll','System.Xaml.dll','System.Windows.Forms.dll','System.Drawing.dll',[Windows.Window].Assembly.Location,[Windows.Media.Brush].Assembly.Location,[Windows.Point].Assembly.Location)
Add-Type -Path @((Join-Path $script:appDir 'runtime/music-audio.cs'),(Join-Path $script:appDir 'runtime/music-visual.cs'),(Join-Path $PSScriptRoot 'music-rhythm-probe.cs')) -ReferencedAssemblies $refs
$rows=@()
foreach($rate in @(44100,48000)){
 foreach($bpm in @(90,120,170)){
  foreach($gain in @(.025,.20)){
   $r=[MusicRhythmProbe]::Run($rate,$bpm,$gain);$rows+=$r
   if($r.Missed -or $r.Extra){throw ('Mixed music missed/double beats: '+($r|ConvertTo-Json -Compress))}
   if($r.LockedFrames-lt 90 -or [Math]::Abs($r.EstimatedBpm-$bpm)-gt 2 -or $r.MaxBeatPhaseError-gt .045 -or $r.MaxPosePhaseError-gt .045){throw ('Musical clock drifted from known drum beats: '+($r|ConvertTo-Json -Compress))}
   if(!$r.Grounded -or !$r.Settled -or $r.MaxDrive-$r.MinDrive-lt .15){throw ('Continuous music response failed: '+($r|ConvertTo-Json -Compress))}
   if($r.MaxFrameChange-gt .28){throw 'Discontinuous character pose'}
  }
 }
}
$result=@{passed=$true;scenarios=$rows;description='Layered bass, kick accents and high hats; varying tempo, volume, silence and continuous motion'}
if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
Write-Output ('PASS: '+$rows.Count+' mixed-music scenarios, 192 onsets with bounded delay, no doubles, confirmed tempo and lowest pose aligned to musical beats')
