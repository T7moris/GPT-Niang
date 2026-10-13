param([string]$PreviewDirectory)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$appDir=Split-Path $PSScriptRoot -Parent
foreach($name in @('audio.ps1','audio-import.ps1','speaker.ps1')){
    . ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $appDir ('runtime\'+$name)),[Text.Encoding]::UTF8)))
}
function Assert($condition,[string]$message){if(!$condition){throw $message};Write-Output ('PASS '+$message)}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-local-sounds-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($testRoot)
$data=Join-Path $testRoot 'state [local]'
try{
    $pair=Import-WidgetSoundPair $data (Join-Path $appDir 'assets\press.wav') (Join-Path $appDir 'assets\release.wav')
    Assert ($null-ne $pair) 'Both WAVs are copied and loaded from the data directory'
    Assert ((Get-FileHash -LiteralPath $pair.Press).Hash-eq (Get-FileHash -LiteralPath (Join-Path $appDir 'assets\press.wav')).Hash) 'Import retains exact audio bytes'
    $manifest=Join-Path $data 'custom-sounds\pair.json';$before=[IO.File]::ReadAllText($manifest)
    $bad=Join-Path $testRoot 'invalid.wav';[IO.File]::WriteAllText($bad,'not audio')
    $rejected=$false
    try{$null=Import-WidgetSoundPair $data $pair.Press $bad}catch{$rejected=$true}
    Assert $rejected 'Invalid second file rejects the complete pair'
    Assert ([IO.File]::ReadAllText($manifest)-eq $before) 'Failed import preserves the previous manifest'
    $soundFolder=Split-Path $manifest -Parent
    $filesBefore=@([IO.Directory]::GetFiles($soundFolder)).Count
    $lock=[IO.File]::Open($manifest,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    $rejected=$false
    try{try{$null=Import-WidgetSoundPair $data $pair.Press $pair.Release}catch{$rejected=$true}}
    finally{$lock.Dispose()}
    Assert ($rejected -and [IO.File]::ReadAllText($manifest)-eq $before -and
        @([IO.Directory]::GetFiles($soundFolder)).Count-eq $filesBefore) 'Manifest write failure preserves the old pair and removes incomplete import files'
    # These files pass a duration-only check but must not be accepted for playback.
    $validBytes=[IO.File]::ReadAllBytes($pair.Press)
    foreach($case in @(
        @{Name='unsupported codec';Offset=20;Bytes=[BitConverter]::GetBytes([uint16]65535)},
        @{Name='inconsistent byte rate';Offset=28;Bytes=[BitConverter]::GetBytes([uint32]176400)},
        @{Name='inconsistent frame alignment';Offset=32;Bytes=[BitConverter]::GetBytes([uint16]4)},
        @{Name='incorrect RIFF size';Offset=4;Bytes=[BitConverter]::GetBytes([uint32]4)}
    )){
        $bytes=$validBytes.Clone();[Array]::Copy($case.Bytes,0,$bytes,$case.Offset,$case.Bytes.Length)
        [IO.File]::WriteAllBytes($bad,$bytes)
        $rejected=$false;try{$null=Import-WidgetSoundPair $data $bad $pair.Release}catch{$rejected=$true}
        Assert ($rejected -and [IO.File]::ReadAllText($manifest)-eq $before) ('Reject '+$case.Name+' without replacing current sounds')
    }
    $stream=[IO.File]::Create($bad);$stream.SetLength(2MB+1);$stream.Dispose()
    $rejected=$false;try{Assert-WidgetImportWave $bad}catch{$rejected=$true}
    Assert $rejected 'Reject a file above the import size limit'
    # Construct a valid 11-second PCM WAV below the byte limit.
    $stream=[IO.File]::Create($bad);$writer=[IO.BinaryWriter]::new($stream)
    try{
        $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'));$writer.Write([uint32](36+88000))
        $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '));$writer.Write([uint32]16)
        $writer.Write([uint16]1);$writer.Write([uint16]1);$writer.Write([uint32]8000);$writer.Write([uint32]8000)
        $writer.Write([uint16]1);$writer.Write([uint16]8);$writer.Write([Text.Encoding]::ASCII.GetBytes('data'))
        $writer.Write([uint32]88000);$writer.Write([byte[]]::new(88000))
    }finally{$writer.Dispose()}
    $rejected=$false;try{Assert-WidgetImportWave $bad}catch{$rejected=$true}
    Assert $rejected 'Reject valid PCM above ten seconds'
    $next=Import-WidgetSoundPair $data $pair.Press $pair.Release
    Assert ($next.Id-ne $pair.Id) 'Reimport creates a complete new pair before switching'
    $paths=Get-WidgetAudioPaths $appDir $data 'custom'
    Assert ($paths.Preset-eq 'custom' -and $paths.Press-eq $next.Press) 'Custom sound survives reloading its manifest'
    $script:appDir=$appDir;$script:dataDir=$data;$script:soundOn=$false;$script:soundVolume=0.25
    $script:savedPreset=$null
    function Save-Settings {$script:savedPreset=$script:soundPreset}
    function Update-WidgetSettingsMenu {}
    Set-WidgetSoundPreset 'custom'
    $oldAudio=$script:gptNiangAudio
    Assert ($oldAudio -and !$oldAudio.Clock.IsRunning -and !$oldAudio.Pressing) 'Selecting imported sounds opens players without starting playback'
    Assert ($script:savedPreset-eq 'custom' -and $oldAudio.Press.Volume-eq 0.25) 'Selection is saved and existing volume retained'
    Play-WidgetPressSound
    Assert (!$oldAudio.Clock.IsRunning) 'Imported sounds obey mute'
    Set-WidgetSoundPreset 'classic';Set-WidgetSoundPreset 'custom'
    $currentAudio=$script:gptNiangAudio
    Invoke-WidgetAudioFailure $oldAudio.Press
    Assert ([object]::ReferenceEquals($script:gptNiangAudio,$currentAudio) -and $script:soundPreset-eq 'custom') 'Late failures from replaced players do not affect the current pair'
    Invoke-WidgetAudioFailure $currentAudio.Release
    Assert ($script:savedPreset-eq 'classic' -and $script:gptNiangAudio -and !$script:gptNiangAudio.Clock.IsRunning) 'Current decoder failure silently restores and saves the original preset'
    Set-WidgetSoundPreset 'custom'
    Invoke-WidgetAudioFailure $script:gptNiangAudio.Press
    Assert ($script:savedPreset-eq 'classic') 'Press decoder failure also restores the original preset'
    [IO.File]::Delete($next.Release)
    Assert ((Get-WidgetAudioPaths $appDir $data 'custom').Preset-eq 'classic') 'Missing custom audio falls back to the original pair'
    [IO.File]::WriteAllText($manifest,'{"id":"../../outside"}')
    Assert ($null-eq (Get-WidgetCustomSoundPair $data)) 'Edited manifests cannot escape the sound directory'

    $script:window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $appDir 'widget.xaml')))
    $script:ui=@{Root=$script:window.FindName('Root');Girl=$script:window.FindName('Girl')}
    $script:ui.Girl.Source=[Windows.Media.Imaging.BitmapImage]::new([Uri](Join-Path $appDir 'assets\gpt-dragon-niang-bust.png'))
    $original=$script:ui.Girl.RenderTransform
    $script:window.Opacity=0;$script:window.Show()
    Set-WidgetSpeakerVisible $true
    $s=$script:widgetSpeaker
    Assert ($s.Running -and $s.Prop.Visibility-eq 'Visible') 'Enabling speaker starts its reveal and pulse'
    Assert (!$s.Prop.IsHitTestVisible) 'Speaker does not block mouse input'
    Assert ($script:ui.Root.Children.IndexOf($s.Prop)-lt $script:ui.Root.Children.IndexOf($script:ui.Girl)) 'Prop is behind the character'
    $script:window.Hide()
    Assert (!$s.Running -and $script:speakerRequested) 'Hiding the host stops animation clocks and retains the toggle'
    $script:window.Show()
    Assert $s.Running 'Restoring visibility resumes animation'
    for($i=0;$i-lt 5;$i++){Set-WidgetSpeakerVisible $false;Set-WidgetSpeakerVisible $true}
    Assert (@($script:ui.Root.Children|Where-Object{$_-eq $s.Prop}).Count-eq 1) 'Repeated toggles reuse one prop'
    Set-WidgetSpeakerVisible $false
    Assert (!$s.Running -and !$s.GirlScale.HasAnimatedProperties -and !$s.Beat.HasAnimatedProperties) 'Stop removes repeating animation clocks'
    Assert ($script:ui.Girl.RenderTransform-eq $original) 'Stop restores the original character transform'
    if($PreviewDirectory){
        $null=[IO.Directory]::CreateDirectory($PreviewDirectory)
        # Static view of the same prop geometry, rendered without showing a second pet.
        $s.Prop.Visibility='Visible'
        $view=$script:window.Content;$view.Measure([Windows.Size]::new(756,756))
        $view.Arrange([Windows.Rect]::new(0,0,756,756));$view.UpdateLayout()
        $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(756,756,96,96,[Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($view);$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new()
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream=[IO.File]::Create((Join-Path $PreviewDirectory 'speaker.png'))
        try{$encoder.Save($stream)}finally{$stream.Dispose()}
    }
}finally{
    if($script:gptNiangAudio){Stop-WidgetAudio;$script:gptNiangAudio.Press.Close();$script:gptNiangAudio.Release.Close()}
    Set-WidgetSpeakerVisible $false
    if($script:window){$script:window.Close()}
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or
       [IO.Path]::GetFileName($resolved)-notmatch '^gpt-niang-local-sounds-[a-f0-9]{32}$'){throw 'Unsafe test cleanup path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
