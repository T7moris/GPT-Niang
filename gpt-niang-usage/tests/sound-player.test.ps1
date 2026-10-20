param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationCore,WindowsBase,System
$appDir=Split-Path $TestRoot -Parent
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $appDir 'runtime/audio.ps1'),[Text.Encoding]::UTF8)))
function Assert-Sound($Value,[string]$Message){if(!$Value){throw $Message}}
function Pump-Sound([int]$Milliseconds){
  $frame=[Windows.Threading.DispatcherFrame]::new();$timer=[Windows.Threading.DispatcherTimer]::new()
  $timer.Interval=[TimeSpan]::FromMilliseconds($Milliseconds)
  $timer.Add_Tick({$timer.Stop();$frame.Continue=$false}.GetNewClosure())
  $timer.Start();[Windows.Threading.Dispatcher]::PushFrame($frame)
}
function Pcm-Peak([byte[]]$Bytes){
  $offset=12
  while($offset+8-le $Bytes.Length){
    $name=[Text.Encoding]::ASCII.GetString($Bytes,$offset,4);$length=[int][BitConverter]::ToUInt32($Bytes,$offset+4)
    if($name-eq 'data'){
      $peak=0
      for($i=$offset+8;$i-lt $offset+8+$length;$i+=2){$peak=[Math]::Max($peak,[Math]::Abs([int][BitConverter]::ToInt16($Bytes,$i)))}
      return $peak
    }
    $offset+=8+$length+($length%2)
  }
  throw 'PCM fixture has no samples'
}
$realFactory=${function:New-WidgetScaledSoundPlayer}
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-sound-'+[Guid]::NewGuid().ToString('N'))
try{
  $original=[IO.File]::ReadAllBytes((Join-Path $appDir 'assets/press.wav'))
  $scaled=& $realFactory (Join-Path $appDir 'assets/press.wav') 0.37
  try{
    Assert-Sound ($scaled.Player-is [System.Media.SoundPlayer] -and $scaled.Player.IsLoadCompleted) 'System WAV player did not preload the clip'
    Assert-Sound ([Math]::Abs((Pcm-Peak $scaled.Stream.ToArray())-(Pcm-Peak $original)*0.37)-le 1) 'Fractional volume did not scale the complete PCM samples'
  }finally{Close-WidgetSoundPlayer $scaled.Player $scaled.Stream}
  # Keep genuine SoundPlayer playback silent without changing system or user volume.
  $script:silentFactory=$realFactory
  function New-WidgetScaledSoundPlayer([string]$Path,[double]$Volume){& $script:silentFactory $Path 0.0}
  $script:soundOn=$true;$script:soundVolume=0.9
  Initialize-WidgetAudio $appDir
  Assert-Sound ($null-ne $script:gptNiangAudio) 'System WAV backend did not initialize'
  Assert-Sound ((Pcm-Peak $script:gptNiangAudio.PressStream.ToArray())-eq 0) 'Native playback fixture is not silent'
  for($i=0;$i-lt 120;$i++){Play-WidgetPressSound;Play-WidgetReleaseSound;Pump-Sound 2}
  for($i=0;$i-lt 3;$i++){
    Play-WidgetPressSound;Play-WidgetReleaseSound
    Pump-Sound ([int][Math]::Ceiling(($script:gptNiangAudio.Duration+0.1)*1000))
    Assert-Sound ($script:gptNiangAudio.ReleasePlayed -and !$script:gptNiangAudio.PendingRelease -and !$script:gptNiangAudio.Timer.IsEnabled) 'Rapid clicks left the next ordinary click pending'
  }
  $script:soundOn=$false;Play-WidgetPressSound
  Assert-Sound (!$script:gptNiangAudio.Pressing -and !$script:gptNiangAudio.Timer.IsEnabled) 'Muted clicks started the timer'
  $script:soundOn=$true;$script:soundVolume=0;Play-WidgetPressSound
  Assert-Sound (!$script:gptNiangAudio.Pressing) 'Zero volume started a pair'
  $script:soundVolume=0.37;Play-WidgetPressSound;Play-WidgetReleaseSound;Stop-WidgetAudio
  Assert-Sound (!$script:gptNiangAudio.PendingRelease -and !$script:gptNiangAudio.Timer.IsEnabled) 'Capture cancellation left a release pending'
  $oldAudio=$script:gptNiangAudio
  Initialize-WidgetAudio $appDir
  Assert-Sound (!$oldAudio.PressStream.CanRead -and !$oldAudio.ReleaseStream.CanRead -and !$oldAudio.Timer.IsEnabled) 'Reinitialization retained old streams or a timer'
  $fixtureAssets=Join-Path $fixtureRoot 'assets';$null=[IO.Directory]::CreateDirectory($fixtureAssets)
  Copy-Item -LiteralPath (Join-Path $appDir 'assets/press.wav') -Destination $fixtureAssets
  Initialize-WidgetAudio $fixtureRoot
  Assert-Sound ($null-eq $script:gptNiangAudio) 'Incomplete clip pair was accepted'
  Copy-Item -LiteralPath (Join-Path $appDir 'assets/release.wav') -Destination $fixtureAssets
  Initialize-WidgetAudio $fixtureRoot
  Assert-Sound ($null-ne $script:gptNiangAudio) 'Reinitialization did not recover a repaired clip pair'
  $lastAudio=$script:gptNiangAudio;Close-WidgetAudio
  Assert-Sound ($null-eq $script:gptNiangAudio -and !$lastAudio.PressStream.CanRead -and !$lastAudio.ReleaseStream.CanRead) 'Shutdown retained WAV resources'
  Write-Output 'PASS: system SoundPlayer preload, fractional PCM volume, silent native 120 rapid clicks and three subsequent ordinary pairs, mute/zero/cancel, reinitialization, missing-file recovery and shutdown cleanup'
}finally{
  Close-WidgetAudio
  ${function:New-WidgetScaledSoundPlayer}=$realFactory
  $resolved=[IO.Path]::GetFullPath($fixtureRoot);$allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
  if(!$resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved)-notlike 'gpt-niang-sound-*'){throw 'Unsafe sound fixture cleanup path'}
  if([IO.Directory]::Exists($resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
