# Independent, synthesized click sounds. Dot-source on the WPF STA thread.
# Initialize only opens the files; it never starts playback.
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

function Get-WidgetWaveSeconds([string]$Path,[switch]$ValidatePcm) {
    # Our WAVs are PCM RIFF files. Parsing duration avoids depending on decoder warmup.
    $reader = $null
    try {
        $reader = New-Object IO.BinaryReader([IO.File]::OpenRead($Path))
        $encoding = [Text.Encoding]::ASCII
        if ($encoding.GetString($reader.ReadBytes(4)) -ne 'RIFF') { throw 'Invalid RIFF file' }
        $riffLength = $reader.ReadUInt32()
        if ($ValidatePcm -and ([long]$riffLength + 8 -ne $reader.BaseStream.Length)) { throw 'Invalid RIFF length' }
        if ($encoding.GetString($reader.ReadBytes(4)) -ne 'WAVE') { throw 'Invalid WAVE file' }
        $rate = 0
        $dataLength = 0
        $formatSeen = $false
        $dataSeen = $false
        $align = 0
        while ($reader.BaseStream.Position + 8 -le $reader.BaseStream.Length) {
            $chunk = $encoding.GetString($reader.ReadBytes(4))
            $length = $reader.ReadUInt32()
            $next = $reader.BaseStream.Position + $length + ($length % 2)
            if ($next -gt $reader.BaseStream.Length) { throw 'Invalid WAVE chunk' }
            if ($chunk -eq 'fmt ') {
                if ($length -lt 16) { throw 'Invalid WAVE format' }
                $format = $reader.ReadUInt16()
                $channels = $reader.ReadUInt16()
                $sampleRate = $reader.ReadUInt32()
                $rate = $reader.ReadUInt32()
                $align = $reader.ReadUInt16()
                $bits = $reader.ReadUInt16()
                if ($ValidatePcm -and ($formatSeen -or $format -ne 1 -or $channels -notin @(1,2) -or
                    $bits -notin @(8,16) -or $sampleRate -lt 8000 -or $sampleRate -gt 192000 -or
                    $align -ne ($channels * $bits / 8) -or $rate -ne ($sampleRate * $align))) {
                    throw 'Please use an 8/16-bit mono or stereo PCM WAV (8-192 kHz).'
                }
                $formatSeen = $true
            } elseif ($chunk -eq 'data') {
                if ($ValidatePcm -and $dataSeen) { throw 'Duplicate WAVE data' }
                $dataLength = $length
                $dataSeen = $true
            }
            $reader.BaseStream.Position = $next
        }
        if ($rate -le 0 -or $dataLength -le 0) { throw 'Missing WAVE audio' }
        if ($ValidatePcm -and (!$formatSeen -or $dataLength % $align -ne 0 -or
            $reader.BaseStream.Position -ne $reader.BaseStream.Length)) { throw 'Invalid PCM data' }
        return [double]$dataLength / $rate
    } finally {
        if ($null -ne $reader) { $reader.Close() }
    }
}

function Set-WidgetAudioVolume {
    param([double]$Volume = -1)
    if ($Volume -ge 0 -and -not [double]::IsNaN($Volume) -and -not [double]::IsInfinity($Volume)) {
        $script:soundVolume = [Math]::Min(1.0, [Math]::Max(0.0, $Volume))
    }
    $value = Get-WidgetAudioVolume
    if ($null -ne $script:gptNiangAudio) {
        try { $script:gptNiangAudio.Press.Volume = $value } catch {}
        try { $script:gptNiangAudio.Release.Volume = $value } catch {}
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
        $audio.Release.Position = [TimeSpan]::Zero
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
        try { $existing.Value.Press.Close() } catch {}
        try { $existing.Value.Release.Close() } catch {}
    }
    $script:gptNiangAudio = $null
    try {
        Add-Type -AssemblyName PresentationCore, WindowsBase
        $paths = Get-WidgetAudioPaths $AppDir $script:dataDir $script:soundPreset
        $script:soundPreset = $paths.Preset
        $pressPath = [IO.Path]::GetFullPath($paths.Press)
        $releasePath = [IO.Path]::GetFullPath($paths.Release)
        $duration = Get-WidgetWaveSeconds $pressPath
        [void](Get-WidgetWaveSeconds $releasePath)
        $press = New-Object Windows.Media.MediaPlayer
        $release = New-Object Windows.Media.MediaPlayer
        $timer = New-Object Windows.Threading.DispatcherTimer
        $script:gptNiangAudio = @{
            Press = $press; Release = $release; Timer = $timer
            Clock = New-Object Diagnostics.Stopwatch
            Duration = $duration; Pressing = $false; PressEnded = $true
            PendingRelease = $false; ReleasePlayed = $true
        }
        $timer.Add_Tick({
            param($sender,$event)
            $audio = $script:gptNiangAudio
            if ($null -eq $audio -or ![object]::ReferenceEquals($sender,$audio.Timer)) { return }
            $audio.Timer.Stop()
            if (-not $audio.PendingRelease -or $audio.Pressing) { return }
            # MediaEnded normally joins the pair. This bounded fallback covers decoder failure.
            # A previously queued Tick may arrive after another press; do not release it early.
            $remaining = $audio.Duration + 0.06 - $audio.Clock.Elapsed.TotalSeconds
            if ($remaining -gt 0.002) {
                $audio.Timer.Interval = [TimeSpan]::FromSeconds($remaining)
                $audio.Timer.Start()
                return
            }
            $audio.PressEnded = $true
            Invoke-WidgetReleaseNow
        })
        $press.Add_MediaEnded({
            param($sender,$event)
            $audio = $script:gptNiangAudio
            if ($null -eq $audio -or ![object]::ReferenceEquals($sender,$audio.Press)) { return }
            # Ignore a delayed old completion delivered after a new press began.
            if ($audio.Clock.Elapsed.TotalSeconds -lt $audio.Duration - 0.02) { return }
            $audio.PressEnded = $true
            if ($audio.PendingRelease -and -not $audio.Pressing) { Invoke-WidgetReleaseNow }
        })
        $press.Add_MediaFailed({
            param($sender,$event)
            Invoke-WidgetAudioFailure $sender
        })
        $release.Add_MediaFailed({param($sender,$event) Invoke-WidgetAudioFailure $sender})
        Set-WidgetAudioVolume
        $press.Open([Uri]$pressPath)
        $release.Open([Uri]$releasePath)
    } catch {
        if ($null -ne $script:gptNiangAudio) {
            Stop-WidgetAudio
            try { $script:gptNiangAudio.Press.Close() } catch {}
            try { $script:gptNiangAudio.Release.Close() } catch {}
        }
        $script:gptNiangAudio = $null
        if ($script:soundPreset -eq 'custom') {
            $script:soundPreset = 'classic'
            Initialize-WidgetAudio -AppDir $AppDir
        }
    }
}

function Invoke-WidgetAudioFailure($Player) {
    $audio = $script:gptNiangAudio
    if ($null -eq $audio -or (![object]::ReferenceEquals($Player,$audio.Press) -and
        ![object]::ReferenceEquals($Player,$audio.Release))) { return }
    # Delayed events from a replaced player cannot alter the current sound pair.
    Stop-WidgetAudio
    if ($script:soundPreset -eq 'custom') {
        $script:soundPreset = 'classic'
        Initialize-WidgetAudio -AppDir $script:appDir
        try { Save-Settings } catch {}
        try { Update-WidgetSettingsMenu } catch {}
    }
}

function Play-WidgetPressSound {
    if ($null -eq $script:gptNiangAudio) { return }
    Stop-WidgetAudio
    if (-not (Get-WidgetAudioEnabled) -or (Get-WidgetAudioVolume) -le 0) { return }
    $audio = $script:gptNiangAudio
    $audio.Pressing = $true
    $audio.PressEnded = $false
    $audio.ReleasePlayed = $false
    $audio.Clock.Restart()
    Set-WidgetAudioVolume
    try {
        $audio.Press.Position = [TimeSpan]::Zero
        $audio.Press.Play()
    } catch { $audio.PressEnded = $true }
}

function Play-WidgetReleaseSound {
    $audio = $script:gptNiangAudio
    if ($null -eq $audio -or -not $audio.Pressing) { return }
    $audio.Pressing = $false
    if (-not (Get-WidgetAudioEnabled) -or (Get-WidgetAudioVolume) -le 0) {
        Stop-WidgetAudio
        return
    }
    $audio.PendingRelease = $true
    if ($audio.PressEnded -or $audio.Clock.Elapsed.TotalSeconds -ge $audio.Duration + 0.06) {
        Invoke-WidgetReleaseNow
        return
    }
    $remaining = [Math]::Max(0.002, $audio.Duration + 0.06 - $audio.Clock.Elapsed.TotalSeconds)
    $audio.Timer.Interval = [TimeSpan]::FromSeconds($remaining)
    $audio.Timer.Start()
}
