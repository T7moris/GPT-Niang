$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'runtime\audio.ps1')
. (Join-Path $root 'runtime\completion-voice.ps1')
. (Join-Path $root 'runtime\completion-notifications.ps1')
function Assert($ok,$message){if(!$ok){throw $message}}
$script:played=0;$script:stopped=0;$script:saved=0;$script:completionNotificationsEnabled=$false;$script:characterMode='original';$script:completionVoiceEnabled=$true
function Save-Settings {$script:saved++}
function Update-CompletionMonitor {}
function Stop-WidgetAudio {$script:stopped++}
Initialize-CompletionVoice $root
Assert ($null-ne $script:completionVoice) 'Asset did not load'
Assert ($script:completionVoice.Duration-gt .4 -and $script:completionVoice.Duration-lt 2) 'Unexpected asset duration'
function Invoke-CompletionVoiceAudio {$script:played++}
function Event($id,$success=$true){return [pscustomobject]@{eventType='task_complete';turnId=$id;success=$success;message='arbitrary text must not be spoken'}}
Assert (Get-CompletionVoicePreference $null) 'Default disabled'
Assert (!(Get-CompletionVoicePreference ([pscustomobject]@{taskCompletionVoice=$false}))) 'Saved false ignored'
Assert (Test-CompletionMonitorNeeded) 'Voice-only did not keep monitor needed'
Request-CompletionVoice (Event 'one') $true
Assert ($script:played-eq 1 -and $script:stopped-eq 1) 'Success did not play'
$script:completionVoice.BusyUntil=0
Request-CompletionVoice (Event 'one') $true
Assert ($script:played-eq 1) 'Duplicate played'
Request-CompletionVoice (Event 'error' $false) $true
Request-CompletionVoice ([pscustomobject]@{eventType='work_state';success=$true;turnId='work'}) $true
Request-CompletionVoice ([pscustomobject]@{eventType='task_complete';success='true';turnId='malformed'}) $true
Assert ($script:played-eq 1) 'Failure/malformed/work signal played'
Request-CompletionVoice (Event 'hidden') $false
Request-CompletionVoice (Event 'hidden') $true
Assert ($script:played-eq 1) 'Hidden task replayed'
Set-CompletionVoiceEnabled $false
Request-CompletionVoice (Event 'muted') $true
Assert ($script:played-eq 1 -and !(Test-CompletionMonitorNeeded)) 'Disabled voice played/monitor stayed needed'
Set-CompletionVoiceEnabled $true
Request-CompletionVoice (Event 'muted') $true
Assert ($script:played-eq 1) 'Muted event replayed'
Receive-CompletionMonitorLine '{"eventType":"task_complete","success":true,"turnId":"pipeline"}' $true
Assert ($script:played-eq 2) 'Completion pipeline did not play independently of bubble'
Request-CompletionVoice (Event 'simultaneous') $true
Assert ($script:played-eq 2) 'Overlapping completion replayed'
for($i=0;$i-lt 140;$i++){Request-CompletionVoice (Event ('bounded'+$i)) $false}
Assert ($script:completionVoiceSeen.Count-le 128) 'Dedupe state grew unbounded'
Assert ($script:saved-eq 2) 'Toggle not persisted'
Close-CompletionVoice
Assert ($null-eq $script:completionVoice) 'Player not disposed'
Write-Output 'PASS: real WAV load, independent toggle/persistence hook, success-only, duplicate/hidden/muted filtering, overlap, bounded memory and disposal'
