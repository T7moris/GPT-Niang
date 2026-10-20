param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System
$appDir=Split-Path $TestRoot -Parent
. (Join-Path $appDir 'runtime/audio.ps1')
. (Join-Path $appDir 'runtime/update-common.ps1')
function Get-FileHash {throw 'Get-FileHash module is unavailable in this fixture.'}
$script:checks=0
function Assert-Audio($Value,[string]$Message){$script:checks++;if(!$Value){throw $Message}}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-audio-import-'+[Guid]::NewGuid().ToString('N'))
$sources=Join-Path $fixture 'source';$data=Join-Path $fixture 'data'
$null=[IO.Directory]::CreateDirectory($data)
$script:config=@{nodePath=(Get-Command node -ErrorAction Stop).Source}
$script:soundOn=$true;$script:soundVolume=0.37
$factory=${function:New-WidgetAudioClip};$script:realAudioFactory=$factory
# Preload and play native PCM clips using silent samples, without changing user/system volume.
function New-WidgetAudioClip([string]$Path,[double]$Volume){& $script:realAudioFactory $Path 0}
function Update-WidgetSettingsMenu {}
function Select-WidgetAudioFile {return $script:selectedSource}
function Show-WidgetAudioError([string]$Message){$script:errorsShown+=,$Message}
$writer=${function:Write-WidgetAudioPreferences}
try{
    & $script:config.nodePath (Join-Path $TestRoot 'wave-fixtures.mjs') $sources
    if($LASTEXITCODE){throw 'Fixture creation failed'}
    Initialize-WidgetAudio $appDir $data
    Assert-Audio ($script:gptNiangAudio.Preferences.mode-eq 'builtin') 'Existing installation did not default to builtin sounds'
    $originalHash=Get-WidgetFileHash (Join-Path $sources 'eight.wav')
    Assert-Audio (Import-WidgetAudio press (Join-Path $sources 'eight.wav')) '8-bit import failed'
    $a=$script:gptNiangAudio
    Assert-Audio ($a.Press -and !$a.Release -and $a.Preferences.mode-eq 'custom') 'Single press import did not leave release silent'
    Assert-Audio ((Get-WidgetFileHash (Join-Path $sources 'eight.wav'))-eq $originalHash) 'Import changed the source'
    Play-WidgetPressSound;Play-WidgetReleaseSound
    Assert-Audio (!$a.Timer.IsEnabled -and !$a.PendingRelease -and $a.ReleasePlayed) 'Press-only release started a timer'
    Assert-Audio (($a.Press-is [byte[]])) 'Press-only playback lost its player'
    Set-WidgetAudioVolume 0.51
    Assert-Audio ($a.Volume-eq 0.51 -and !$a.Release) 'Fractional volume failed with an empty slot'
    Clear-WidgetAudioSlot press
    Play-WidgetPressSound;Play-WidgetReleaseSound
    Assert-Audio (!$script:gptNiangAudio.Press -and !$script:gptNiangAudio.Release -and !$script:gptNiangAudio.Timer.IsEnabled) 'Double silence was replaced or started a timer'
    $null=Import-WidgetAudio release (Join-Path $sources 'float.wav')
    $a=$script:gptNiangAudio
    Play-WidgetPressSound;Play-WidgetReleaseSound
    Assert-Audio (!$a.Press -and $a.Release -and $a.ReleasePlayed -and !$a.PendingRelease -and !$a.Timer.IsEnabled) 'Release-only audio did not play immediately'
    $null=Import-WidgetAudio press (Join-Path $sources 'twenty-four.wav')
    Assert-Audio ($script:gptNiangAudio.Press -and $script:gptNiangAudio.Release) 'Changing one slot cleared the other'
    $script:soundOn=$false;Play-WidgetPressSound
    Assert-Audio (!$script:gptNiangAudio.Pressing) 'Muted custom audio started a click'
    $script:soundOn=$true;Set-WidgetAudioVolume 0;Play-WidgetPressSound
    Assert-Audio (!$script:gptNiangAudio.Pressing) 'Zero-volume custom audio started a click'
    Set-WidgetAudioVolume 0.37
    $script:selectedSource=$null;$script:errorsShown=@();$before=$script:gptNiangAudio
    Invoke-WidgetAudioAction import press
    Assert-Audio ([object]::ReferenceEquals($before,$script:gptNiangAudio) -and $script:errorsShown.Count-eq 0) 'Cancel changed settings or showed an error'
    foreach($name in @('unsupported.wav','broken.wav','long.wav')){
        $script:errorsShown=@();$script:selectedSource=Join-Path $sources $name
        $before=$script:gptNiangAudio;$saved=[IO.File]::ReadAllText((Join-Path $data 'audio-preferences.json'))
        $count=@(Get-ChildItem -LiteralPath (Join-Path $data 'sounds') -File).Count
        Invoke-WidgetAudioAction import press
        Assert-Audio ($script:errorsShown.Count-eq 1 -and $script:errorsShown[0].Contains($name)) 'Invalid import did not show one filename-specific error'
        Assert-Audio ([object]::ReferenceEquals($before,$script:gptNiangAudio)) 'Invalid import replaced working audio'
        Assert-Audio ($saved-eq [IO.File]::ReadAllText((Join-Path $data 'audio-preferences.json'))) 'Invalid import changed saved preferences'
        Assert-Audio ($count-eq @(Get-ChildItem -LiteralPath (Join-Path $data 'sounds') -File).Count) 'Invalid import leaked a cache'
        Assert-Audio (!$script:audioDialogOpen) 'Failed import left the updater/notification guard active'
    }
    Assert-Audio ($script:errorsShown[0].Contains('5秒')) 'Duration failure did not explain the five-second limit'
    $before=$script:gptNiangAudio;$saved=[IO.File]::ReadAllText((Join-Path $data 'audio-preferences.json'))
    function Write-WidgetAudioPreferences {throw 'Simulated settings write failure'}
    try{$null=Import-WidgetAudio press (Join-Path $sources 'silent.wav');throw 'Write failure unexpectedly succeeded'}catch{Assert-Audio ($_.Exception.Message.Contains('Simulated')) 'Unexpected write-failure reason'}
    Assert-Audio ([object]::ReferenceEquals($before,$script:gptNiangAudio) -and $saved-eq [IO.File]::ReadAllText((Join-Path $data 'audio-preferences.json'))) 'Write failure did not roll back both runtime and disk'
    ${function:Write-WidgetAudioPreferences}=$writer
    $null=Import-WidgetAudio press (Join-Path $sources 'five.wav')
    Assert-Audio ($script:gptNiangAudio.Duration-eq 5) 'Exactly five seconds was rejected'
    $timer=[Diagnostics.Stopwatch]::StartNew();$null=Import-WidgetAudio release (Join-Path $sources 'high-rate.wav');$timer.Stop()
    Assert-Audio (($script:gptNiangAudio.Release-is [byte[]])) 'High-rate five-second stereo import did not preload'
    $prefs=Copy-WidgetAudioPreferences $script:gptNiangAudio.Preferences
    Set-WidgetAudioMode builtin
    Assert-Audio ($script:gptNiangAudio.Press -and $script:gptNiangAudio.Release) 'Builtin restore failed'
    Set-WidgetAudioMode custom
    Assert-Audio ($script:gptNiangAudio.Preferences.press.file-eq $prefs.press.file) 'Builtin switch discarded the custom file'
    Clear-WidgetAudioSlot press;Close-WidgetAudio
    Initialize-WidgetAudio $appDir $data
    Assert-Audio (!$script:gptNiangAudio.Press -and $script:gptNiangAudio.Release) 'Restart lost explicit silence or valid release'
    $missing=Get-WidgetCustomAudioPath $script:gptNiangAudio release
    [IO.File]::Move($missing,$missing+'.moved');Close-WidgetAudio
    Initialize-WidgetAudio $appDir $data
    Assert-Audio ($script:gptNiangAudio -and !$script:gptNiangAudio.Press -and !$script:gptNiangAudio.Release -and $script:gptNiangAudio.Errors.release) 'Missing cache broke startup or played fallback audio'
    $state=Get-WidgetAudioStatus
    Assert-Audio ($state.ready -and !$state.press.active -and !$state.release.available) 'Empty-slot status reporting failed'
    $script:errorsShown=@();Invoke-WidgetAudioAction preview release
    Assert-Audio ($script:errorsShown.Count-eq 1) 'Missing preview file did not report an error'
    # Preferences cannot redirect cache reads outside the personal sounds directory.
    [IO.File]::WriteAllText((Join-Path $data 'audio-preferences.json'),'{"version":1,"mode":"custom","press":{"file":"../outside.wav","name":"bad"},"release":null}')
    Close-WidgetAudio;Initialize-WidgetAudio $appDir $data
    Assert-Audio ($script:gptNiangAudio.Preferences.loadError -and !$script:gptNiangAudio.Press) 'Invalid cache path was accepted'
    Write-Output "PASS: $script:checks audio import checks; real silent native playback, four slot combinations, five-second boundary, errors, atomic rollback, persistence, missing cache, fractional volume and mute. High-rate import $($timer.ElapsedMilliseconds)ms"
}finally{
    Close-WidgetAudio;${function:New-WidgetAudioClip}=$factory;${function:Write-WidgetAudioPreferences}=$writer
    $resolved=[IO.Path]::GetFullPath($fixture);$allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved)-notlike 'gpt-niang-audio-import-*'){throw 'Unsafe fixture cleanup'}
    if([IO.Directory]::Exists($resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
