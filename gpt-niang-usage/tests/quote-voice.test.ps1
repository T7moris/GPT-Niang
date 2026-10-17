$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'runtime\audio.ps1')
. (Join-Path $root 'runtime\completion-voice.ps1')
. (Join-Path $root 'runtime\quote-voice.ps1')
function Assert($ok,$message){if(!$ok){throw $message}}
$script:appDir=$root;$script:dataDir=Join-Path ([IO.Path]::GetTempPath()) ('quote voice '+[Guid]::NewGuid().ToString('N'))
$script:config=@{nodePath=(Get-Command node.exe).Source};$script:window=[pscustomobject]@{IsVisible=$true}
$script:collapsed=$false;$script:bubbleMode='quote';$script:quoteVoiceEnabled=$true;$script:plays=0;$script:saves=0
function Invoke-QuoteVoiceAudio {$script:plays++}
function Save-Settings {$script:saves++}
function Wait-Quote { $end=[DateTime]::UtcNow.AddSeconds(12);while($script:quoteVoiceProcess -and [DateTime]::UtcNow-lt $end){Pump-QuoteVoice $true;Start-Sleep -Milliseconds 25};Assert (!$script:quoteVoiceProcess) 'Quote child did not finish';Assert (!$script:quoteVoiceError) $script:quoteVoiceError }
try{
  Assert (Get-QuoteVoicePreference $null) 'Default disabled'
  Assert (!(Get-QuoteVoicePreference ([pscustomobject]@{quoteVoice=$false}))) 'Saved mute ignored'
  Request-QuoteVoice '你好，小星星！Hello。'
  Assert ($null-ne $script:quoteVoiceProcess) ('No child: '+$script:quoteVoiceError)
  Wait-Quote
  Assert ($script:plays-eq 1 -and (Test-QuoteVoiceBusy)) 'Quote did not play'
  $script:bubbleMode='quota';Pump-QuoteVoice $true
  Assert (!$script:quoteVoiceSound -and !(Test-QuoteVoiceBusy)) 'Quota did not stop quote'
  Request-QuoteVoice '额度不发声'
  Assert (!$script:quoteVoiceProcess -and $script:plays-eq 1) 'Quota spoke'
  $script:bubbleMode='quote';Request-QuoteVoice '第一句';$old=$script:quoteVoiceProcess
  Request-QuoteVoice '第二句';Assert ($script:quoteVoiceProcess-ne $old) 'New quote did not supersede old child'
  Wait-Quote;Assert ($script:plays-eq 2) 'Superseded child played late'
  Request-QuoteVoice '准备关闭';Set-QuoteVoiceEnabled $false
  Assert (!$script:quoteVoiceProcess -and !$script:quoteVoiceSound) 'Mute left process or sound alive'
  Request-QuoteVoice '关闭后';Assert (!$script:quoteVoiceProcess) 'Muted quote rendered'
  Set-QuoteVoiceEnabled $true
  $script:window.IsVisible=$false;Request-QuoteVoice '隐藏时';Assert (!$script:quoteVoiceProcess) 'Hidden quote rendered'
  $script:window.IsVisible=$true;Request-QuoteVoice '隐藏清理';Pump-QuoteVoice $false
  Assert (!$script:quoteVoiceProcess) 'Hide left child alive'
  $script:completionVoice=[pscustomobject]@{BusyUntil=([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()+5000)}
  Request-QuoteVoice '任务提醒优先';Assert (!$script:quoteVoiceProcess) 'Quote interrupted completion voice'
  $script:completionVoice=$null
  $script:sceneDeadline=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()+5000
  Request-QuoteVoice ('小星星' * 20);Wait-Quote
  Assert ($script:sceneDeadline-ge $script:quoteVoiceBusyUntil -and $script:sceneDeadline-gt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()+5000) 'Long quote cut by normal bubble TTL'
  Assert ($script:saves-eq 2) 'Toggle save hook did not run'
  Write-Output 'PASS: dynamic quote render/load, custom Unicode, quota silence, cancellation, mute, hidden cleanup and completion priority'
}finally{Stop-QuoteVoice;if(Test-Path -LiteralPath $script:dataDir){Remove-Item -LiteralPath $script:dataDir -Recurse -Force}}
