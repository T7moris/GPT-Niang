# Local diagnostic replacement for the widget audio backend.
# Keeps the existing public functions and press/release sequencing, but uses
# System.Media.SoundPlayer with volume-scaled PCM WAV data.
if ($null -eq (Get-Variable -Name gptNiangAudio -Scope Script -ErrorAction SilentlyContinue)) {
    $script:gptNiangAudio = $null
}

function Get-WidgetAudioEnabled {
    $setting = Get-Variable -Name soundOn -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $setting) { return $true }
    return ($setting.Value -ne $false)
}

function Get-WidgetAudioVolume {
    $setting = Get-Variable -Name soundVolume -Scope Script -ErrorAction SilentlyContinue
    $value = 0.9
    if ($null -ne $setting) {
        try { $value = [double]$setting.Value } catch { $value = 0.9 }
    }
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { $value = 0.9 }
    return [Math]::Min(1.0, [Math]::Max(0.0, $value))
}

function Get-WidgetWaveSeconds([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 12 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'RIFF' -or
        [Text.Encoding]::ASCII.GetString($bytes, 8, 4) -ne 'WAVE') { throw 'Invalid RIFF/WAVE file' }
    $byteRate = 0
    $dataLength = 0
    $offset = 12
    while ($offset + 8 -le $bytes.Length) {
        $chunk = [Text.Encoding]::ASCII.GetString($bytes, $offset, 4)
        $size = [long][BitConverter]::ToUInt32($bytes, $offset + 4)
        $body = $offset + 8
        if ($size -gt ($bytes.Length - $body)) { throw 'Invalid WAVE chunk' }
        if ($chunk -eq 'fmt ') {
            if ($size -lt 16) { throw 'Invalid WAVE format' }
            $byteRate = [BitConverter]::ToUInt32($bytes, $body + 8)
        } elseif ($chunk -eq 'data') {
            $dataLength = $size
        }
        $offset = $body + $size + ($size % 2)
    }
    if ($byteRate -le 0 -or $dataLength -le 0) { throw 'Missing WAVE audio' }
    return [double]$dataLength / $byteRate
}

function New-WidgetScaledSoundPlayer([string]$Path, [double]$Volume) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 12 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'RIFF' -or
        [Text.Encoding]::ASCII.GetString($bytes, 8, 4) -ne 'WAVE') { throw 'Invalid RIFF/WAVE file' }
    $formatTag = 0
    $bitsPerSample = 0
    $dataOffset = -1
    $dataLength = 0
    $offset = 12
    while ($offset + 8 -le $bytes.Length) {
        $chunk = [Text.Encoding]::ASCII.GetString($bytes, $offset, 4)
        $size = [long][BitConverter]::ToUInt32($bytes, $offset + 4)
        $body = $offset + 8
        if ($size -gt ($bytes.Length - $body)) { throw 'Invalid WAVE chunk' }
        if ($chunk -eq 'fmt ') {
            if ($size -lt 16) { throw 'Invalid WAVE format' }
            $formatTag = [BitConverter]::ToUInt16($bytes, $body)
            $bitsPerSample = [BitConverter]::ToUInt16($bytes, $body + 14)
        } elseif ($chunk -eq 'data') {
            $dataOffset = $body
            $dataLength = $size
        }
        $offset = $body + $size + ($size % 2)
    }
    if ($formatTag -ne 1 -or $bitsPerSample -ne 16 -or $dataOffset -lt 0 -or $dataLength -le 0 -or ($dataLength % 2) -ne 0) {
        throw 'Expected 16-bit PCM WAVE audio'
    }
    $scaled = [byte[]]::new($bytes.Length)
    [Array]::Copy($bytes, $scaled, $bytes.Length)
    $end = $dataOffset + [int]$dataLength
    for ($i = $dataOffset; $i -lt $end; $i += 2) {
        $sample = [int][BitConverter]::ToInt16($bytes, $i)
        $sample = [int][Math]::Round($sample * $Volume, [MidpointRounding]::AwayFromZero)
        if ($sample -gt 32767) { $sample = 32767 }
        if ($sample -lt -32768) { $sample = -32768 }
        $sampleBytes = [BitConverter]::GetBytes([int16]$sample)
        $scaled[$i] = $sampleBytes[0]
        $scaled[$i + 1] = $sampleBytes[1]
    }
    $stream = [IO.MemoryStream]::new($scaled)
    try {
        $player = [System.Media.SoundPlayer]::new($stream)
        $player.Load()
        return [pscustomobject]@{ Player = $player; Stream = $stream }
    } catch {
        $stream.Dispose()
        throw
    }
}

function Close-WidgetSoundPlayer($Player, $Stream) {
    if ($null -ne $Player) {
        try { $Player.Stop() } catch {}
        try { $Player.Dispose() } catch {}
    }
    if ($null -ne $Stream) { try { $Stream.Dispose() } catch {} }
}

function Set-WidgetAudioVolume {
    param([double]$Volume = -1)
    if ($Volume -ge 0 -and -not [double]::IsNaN($Volume) -and -not [double]::IsInfinity($Volume)) {
        $script:soundVolume = [Math]::Min(1.0, [Math]::Max(0.0, $Volume))
    }
    $value = Get-WidgetAudioVolume
    $audio = $script:gptNiangAudio
    if ($null -eq $audio -or [Math]::Abs($audio.Volume - $value) -lt 0.000001) { return }
    $newPress = $null
    $newRelease = $null
    try {
        $newPress = New-WidgetScaledSoundPlayer $audio.PressPath $value
        $newRelease = New-WidgetScaledSoundPlayer $audio.ReleasePath $value
        $oldPress = $audio.Press
        $oldPressStream = $audio.PressStream
        $oldRelease = $audio.Release
        $oldReleaseStream = $audio.ReleaseStream
        Close-WidgetSoundPlayer $oldPress $oldPressStream
        Close-WidgetSoundPlayer $oldRelease $oldReleaseStream
        $audio.Press = $newPress.Player
        $audio.PressStream = $newPress.Stream
        $audio.Release = $newRelease.Player
        $audio.ReleaseStream = $newRelease.Stream
        $audio.Volume = $value
    } catch {
        if ($null -ne $newPress) { Close-WidgetSoundPlayer $newPress.Player $newPress.Stream }
        if ($null -ne $newRelease) { Close-WidgetSoundPlayer $newRelease.Player $newRelease.Stream }
        $script:soundVolume = $audio.Volume
    }
}

function Invoke-WidgetReleaseNow {
    $audio = $script:gptNiangAudio
    if ($null -eq $audio -or -not $audio.PendingRelease -or $audio.ReleasePlayed) { return }
    $audio.Timer.Stop()
    $audio.PendingRelease = $false
    $audio.ReleasePlayed = $true
    if (-not (Get-WidgetAudioEnabled) -or (Get-WidgetAudioVolume) -le 0) { return }
    Set-WidgetAudioVolume
    try {
        $audio.Press.Stop()
        $audio.Release.Stop()
        $audio.Release.Play()
    } catch { $audio.PendingRelease = $false }
}

function Stop-WidgetAudio {
    if ($null -eq $script:gptNiangAudio) { return }
    $audio = $script:gptNiangAudio
    $audio.Timer.Stop()
    $audio.PendingRelease = $false
    $audio.ReleasePlayed = $true
    $audio.Pressing = $false
    $audio.PressEnded = $true
    $audio.Clock.Reset()
    try { $audio.Press.Stop() } catch {}
    try { $audio.Release.Stop() } catch {}
}

function Initialize-WidgetAudio {
    param([Parameter(Mandatory = $true)][string]$AppDir)
    $existing = Get-Variable -Name gptNiangAudio -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $existing -and $null -ne $existing.Value) {
        Stop-WidgetAudio
        Close-WidgetSoundPlayer $existing.Value.Press $existing.Value.PressStream
        Close-WidgetSoundPlayer $existing.Value.Release $existing.Value.ReleaseStream
    }
    $script:gptNiangAudio = $null
    try {
        Add-Type -AssemblyName PresentationCore, WindowsBase, System
        $pressPath = [IO.Path]::GetFullPath((Join-Path $AppDir 'assets/press.wav'))
        $releasePath = [IO.Path]::GetFullPath((Join-Path $AppDir 'assets/release.wav'))
        $volume = Get-WidgetAudioVolume
        $press = New-WidgetScaledSoundPlayer $pressPath $volume
        try { $release = New-WidgetScaledSoundPlayer $releasePath $volume } catch {
            Close-WidgetSoundPlayer $press.Player $press.Stream
            throw
        }
        $duration = Get-WidgetWaveSeconds $pressPath
        $timer = New-Object Windows.Threading.DispatcherTimer
        $script:gptNiangAudio = @{
            Press = $press.Player; PressStream = $press.Stream
            Release = $release.Player; ReleaseStream = $release.Stream
            PressPath = $pressPath; ReleasePath = $releasePath; Volume = $volume
            Timer = $timer; Clock = New-Object Diagnostics.Stopwatch
            Duration = $duration; Pressing = $false; PressEnded = $true
            PendingRelease = $false; ReleasePlayed = $true
        }
        $timer.Add_Tick({
            $audio = $script:gptNiangAudio
            if ($null -eq $audio) { return }
            $audio.Timer.Stop()
            if (-not $audio.PendingRelease -or $audio.Pressing) { return }
            $remaining = $audio.Duration + 0.06 - $audio.Clock.Elapsed.TotalSeconds
            if ($remaining -gt 0.002) {
                $audio.Timer.Interval = [TimeSpan]::FromSeconds($remaining)
                $audio.Timer.Start()
                return
            }
            $audio.PressEnded = $true
            Invoke-WidgetReleaseNow
        })
    } catch {
        if ($null -ne $script:gptNiangAudio) { Stop-WidgetAudio }
        $script:gptNiangAudio = $null
    }
}

function Play-WidgetPressSound {
    if((Get-Command Test-QuoteVoiceBusy -ErrorAction SilentlyContinue) -and (Test-QuoteVoiceBusy)){return}
    if((Get-Command Test-CompletionVoiceBusy -ErrorAction SilentlyContinue) -and (Test-CompletionVoiceBusy)){return}
    if ($null -eq $script:gptNiangAudio) { return }
    Stop-WidgetAudio
    if (-not (Get-WidgetAudioEnabled) -or (Get-WidgetAudioVolume) -le 0) { return }
    $audio = $script:gptNiangAudio
    $audio.Pressing = $true
    $audio.PressEnded = $false
    $audio.ReleasePlayed = $false
    $audio.Clock.Restart()
    Set-WidgetAudioVolume
    try { $audio.Press.Play() } catch { $audio.PressEnded = $true }
}

function Play-WidgetReleaseSound {
    if((Get-Command Test-QuoteVoiceBusy -ErrorAction SilentlyContinue) -and (Test-QuoteVoiceBusy)){return}
    if((Get-Command Test-CompletionVoiceBusy -ErrorAction SilentlyContinue) -and (Test-CompletionVoiceBusy)){return}
    $audio = $script:gptNiangAudio
    if ($null -eq $audio -or -not $audio.Pressing) { return }
    $audio.Pressing = $false
    if (-not (Get-WidgetAudioEnabled) -or (Get-WidgetAudioVolume) -le 0) {
        Stop-WidgetAudio
        return
    }
    $audio.PendingRelease = $true
    $remaining = $audio.Duration + 0.06 - $audio.Clock.Elapsed.TotalSeconds
    if ($remaining -le 0.002) {
        $audio.PressEnded = $true
        Invoke-WidgetReleaseNow
        return
    }
    $audio.Timer.Interval = [TimeSpan]::FromSeconds($remaining)
    $audio.Timer.Start()
}
