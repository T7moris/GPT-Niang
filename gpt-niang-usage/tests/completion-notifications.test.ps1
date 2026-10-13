$ErrorActionPreference='Stop'
$appDir=Split-Path $PSScriptRoot -Parent
. (Join-Path $appDir 'runtime\completion-notifications.ps1')
function Assert-Equal($actual,$expected,[string]$message){if($actual-ne $expected){throw "$message : expected '$expected', got '$actual'"}}
function Start-CompletionMonitor {}
function Read-CompletionMonitorOutput([bool]$Visible) {}
function Save-Settings {}
function Show-CompletionBubble([string]$Message){
  $script:shownMessages+=,$Message
  $script:collapsed=$false;$script:bubbleMode='completion'
}
function Hide-Quota {$script:collapsed=$true}

$script:completionNotificationsEnabled=$true
Initialize-CompletionNotificationState
$script:shownMessages=@();$script:collapsed=$true;$script:bubbleMode='quota';$script:closeTimer=$null

# While hidden, only the newest completion is retained.
Queue-CompletionNotification -Message '隐藏旧提醒' -Visible $false
Queue-CompletionNotification -Message '隐藏最新提醒' -Visible $false
Assert-Equal $script:completionQueue.Count 0 'Hidden reminders do not enter the visible FIFO'
Pump-CompletionNotifications $false
Pump-CompletionNotifications $true
Assert-Equal ($script:shownMessages -join '|') '隐藏最新提醒' 'Showing the widget presents the latest hidden reminder'

# Visible tasks are presented one by one, in arrival order.
$script:collapsed=$true;$script:bubbleMode='quota';$script:shownMessages=@()
Queue-CompletionNotification -Message '任务一' -Visible $true
Queue-CompletionNotification -Message '任务二' -Visible $true
Pump-CompletionNotifications $true
Assert-Equal ($script:shownMessages -join '|') '任务一' 'First visible task is shown first'
Pump-CompletionNotifications $true
Assert-Equal ($script:shownMessages -join '|') '任务一' 'An active completion bubble is not replaced by the next task'
$script:collapsed=$true
Pump-CompletionNotifications $true
Assert-Equal ($script:shownMessages -join '|') '任务一|任务二' 'Next visible task follows after the active bubble closes'

# A completion reminder immediately replaces an open quota or quote bubble.
$script:shownMessages=@();$script:collapsed=$false;$script:bubbleMode='quota'
Queue-CompletionNotification -Message 'Codex 已完成：已更新' -Visible $true
Pump-CompletionNotifications $true
Assert-Equal ($script:shownMessages -join '|') 'Codex 已完成：已更新' 'Completion replaces an open quota bubble immediately'

# Turning the setting off stops the monitor and clears visible and hidden work.
$script:collapsed=$true
Queue-CompletionNotification -Message '待清除' -Visible $false
Set-CompletionNotificationEnabled $false
Assert-Equal $script:completionQueue.Count 0 'Disabling clears queued notifications'
Assert-Equal $script:completionPendingMessage $null 'Disabling clears a hidden pending notification'
Assert-Equal $script:completionNotificationsEnabled $false 'Disabled state is retained'
Set-CompletionNotificationEnabled $true
Assert-Equal $script:completionNotificationsEnabled $true 'The setting can be enabled again'

Write-Output 'PASS: hidden latest reminder, visible FIFO, immediate bubble replacement and disable clearing'
