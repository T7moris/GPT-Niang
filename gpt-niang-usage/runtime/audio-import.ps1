# User-owned sounds stay in the data directory, outside the installed/released assets.
function Assert-WidgetImportWave([string]$Path) {
    $file=Get-Item -LiteralPath $Path -ErrorAction Stop
    if($file.PSIsContainer -or $file.Length-gt 2MB){throw '请选择小于 2 MB 的 WAV 音效。'}
    $seconds=Get-WidgetWaveSeconds $file.FullName -ValidatePcm
    if($seconds-le 0 -or $seconds-gt 10){throw '每段音效需为 0–10 秒的 WAV 文件。'}
}

function Get-WidgetCustomSoundPair([string]$DataDir) {
    if(!$DataDir){return $null}
    try{
        $folder=Join-Path $DataDir 'custom-sounds'
        $pair=Get-Content -LiteralPath (Join-Path $folder 'pair.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        # The manifest cannot point outside this folder, even if edited by hand.
        if([string]$pair.id-cnotmatch '^[a-f0-9]{32}$'){return $null}
        $press=Join-Path $folder ($pair.id+'-press.wav')
        $release=Join-Path $folder ($pair.id+'-release.wav')
        Assert-WidgetImportWave $press;Assert-WidgetImportWave $release
        return @{Press=$press;Release=$release;Id=$pair.id}
    }catch{return $null}
}

function Import-WidgetSoundPair([string]$DataDir,[string]$PressPath,[string]$ReleasePath) {
    # Validate both first. An invalid/cancelled second file must retain the previous pair.
    Assert-WidgetImportWave $PressPath;Assert-WidgetImportWave $ReleasePath
    $folder=[IO.Path]::GetFullPath((Join-Path $DataDir 'custom-sounds'))
    $null=[IO.Directory]::CreateDirectory($folder)
    $id=[Guid]::NewGuid().ToString('N')
    $press=Join-Path $folder ($id+'-press.wav');$release=Join-Path $folder ($id+'-release.wav')
    $temp=Join-Path $folder ($id+'.json.tmp');$manifest=Join-Path $folder 'pair.json'
    try{
        [IO.File]::Copy([IO.Path]::GetFullPath($PressPath),$press)
        [IO.File]::Copy([IO.Path]::GetFullPath($ReleasePath),$release)
        Assert-WidgetImportWave $press;Assert-WidgetImportWave $release
        [IO.File]::WriteAllText($temp,(@{id=$id}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        if([IO.File]::Exists($manifest)){[IO.File]::Replace($temp,$manifest,($manifest+'.bak'))}
        else{[IO.File]::Move($temp,$manifest)}
    }catch{
        # Only remove the exact files created by this failed import; never user source files.
        foreach($path in @($temp,$press,$release)){if([IO.File]::Exists($path)){[IO.File]::Delete($path)}}
        throw
    }
    return Get-WidgetCustomSoundPair $DataDir
}

function Get-WidgetAudioPaths([string]$AppDir,[string]$DataDir,[string]$Preset) {
    if($Preset-eq 'custom'){
        $pair=Get-WidgetCustomSoundPair $DataDir
        if($pair){return @{Press=$pair.Press;Release=$pair.Release;Preset='custom'}}
    }
    return @{Press=(Join-Path $AppDir 'assets/press.wav');Release=(Join-Path $AppDir 'assets/release.wav');Preset='classic'}
}

function Set-WidgetSoundPreset([string]$Preset) {
    if($Preset-notin @('classic','custom')){return}
    if($Preset-eq 'custom' -and !(Get-WidgetCustomSoundPair $script:dataDir)){return}
    $script:soundPreset=$Preset
    Initialize-WidgetAudio -AppDir $script:appDir
    Save-Settings;Update-WidgetSettingsMenu
}

function Open-WidgetSoundImport {
    try{
        $press=[Microsoft.Win32.OpenFileDialog]::new()
        $press.Title='选择按下时的音效';$press.Filter='WAV 音效 (*.wav)|*.wav';$press.CheckFileExists=$true
        if($press.ShowDialog($script:window)-ne $true){return}
        $release=[Microsoft.Win32.OpenFileDialog]::new()
        $release.Title='选择松开时的音效';$release.Filter=$press.Filter;$release.CheckFileExists=$true
        if($release.ShowDialog($script:window)-ne $true){return}
        $null=Import-WidgetSoundPair $script:dataDir $press.FileName $release.FileName
        Set-WidgetSoundPreset 'custom'
    }catch{
        [Windows.MessageBox]::Show($script:window,$_.Exception.Message,'音效导入失败')|Out-Null
    }
}
