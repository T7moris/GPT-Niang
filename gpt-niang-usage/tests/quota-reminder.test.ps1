param([string]$AppRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$checks=0
function Assert($Condition,[string]$Message){if(!$Condition){throw $Message};$script:checks++}
function Load-Functions([string]$File,[string[]]$Names){
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($File,[Text.Encoding]::UTF8),[ref]$tokens,[ref]$errors)
  if($errors.Count){throw ($errors|Out-String)}
  foreach($name in $Names){
    $definition=$ast.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq $name},$true)
    if(!$definition){throw ('Missing production function: '+$name)}
    . ([scriptblock]::Create($definition.Extent.Text))
    Set-Item -Path ('function:script:'+$name) -Value (Get-Item ('function:'+$name)).ScriptBlock
  }
}
Load-Functions (Join-Path $AppRoot 'widget.ps1') @('Update-QuotaStepState','Set-QuotaStepReminderEnabled','Tick-QuotaStepReminder','Write-WidgetJson','Save-Settings')
Load-Functions (Join-Path $AppRoot 'runtime\color-theme.ps1') @('Get-QuotaBarColor','Restore-WidgetOriginalColors','Update-WidgetColorScene')
function New-State {return @{windows=@{};account=$null;pending=$false;displayCount=0}}
function Acknowledge($State){foreach($window in $State.windows.Values){$window.pending=$false};$State.pending=$false}
function Snapshot([double]$Remaining,[long]$Reset=2000,[string]$Account='one'){
  return @{ok=$true;queryOk=$true;accountKey=$Account;windows=@(@{minutes=300;remaining=$Remaining;used=(100-$Remaining);resetsAt=$Reset})}
}
$state=New-State
Update-QuotaStepState $state (Snapshot 47) 1000
Assert (!$state.pending) 'First reading must only establish the baseline'
Update-QuotaStepState $state (Snapshot 46) 1000
Assert (!$state.pending) '47 to 46 must not cross a threshold'
Update-QuotaStepState $state (Snapshot 44) 1000
Assert $state.pending '47 to 44 must cross 45 percent'
Acknowledge $state
Update-QuotaStepState $state (Snapshot 44) 1000
Assert (!$state.pending) 'Repeated data must not repeat a reminder'
Update-QuotaStepState $state (Snapshot 46) 1000
Update-QuotaStepState $state (Snapshot 44) 1000
Assert (!$state.pending) 'A corrected estimate must not repeat the same threshold'
Update-QuotaStepState $state (Snapshot 29) 1000
Assert ($state.pending -and $state.windows['300'].bucket-eq 6) 'A multi-threshold drop must coalesce to one pending reminder'
Acknowledge $state
$failed=Snapshot 24;$failed.queryOk=$false
Update-QuotaStepState $state $failed 1000
Assert (!$state.pending -and $state.windows['300'].bucket-eq 6) 'A failed query must not consume a threshold'
Update-QuotaStepState $state (Snapshot 24) 1000
Assert $state.pending 'The next successful query must still detect the drop'
Update-QuotaStepState $state (Snapshot 100 3000) 1000
Assert (!$state.pending) 'A new reset window must establish a new baseline'
Update-QuotaStepState $state (Snapshot 95 3000) 1000
Assert $state.pending 'Reaching an exact threshold must trigger'
Update-QuotaStepState $state (Snapshot 40 3000 'two') 1000
Assert (!$state.pending) 'Changing account must clear an old pending reminder'
Update-QuotaStepState $state (Snapshot 35 500) 1000
Assert (!$state.pending -and $state.windows.Count-eq 0) 'Expired windows must not trigger'
Update-QuotaStepState $state (Snapshot 45.01) 1000
Update-QuotaStepState $state (Snapshot 45) 1000
Assert $state.pending 'Fractional values must cross exactly at 45 percent'
Update-QuotaStepState $state @{ok=$true;queryOk=$true;windows=@(@{minutes=10080;remaining=5})} 1000
Assert (!$state.pending -and $state.windows.Count-eq 1 -and $state.windows.ContainsKey('10080')) 'Weekly-only plans establish their own baseline'
Update-QuotaStepState $state @{ok=$true;queryOk=$true;windows=@(@{minutes=10080;remaining=0})} 1000
Assert $state.pending 'Weekly-only plans must alert on crossing a threshold'
function Pair([double]$Short,[double]$Week,[long]$ShortReset=2000,[long]$WeekReset=4000){
  $snapshot=Snapshot $Short $ShortReset
  $snapshot.windows+=@{minutes=10080;remaining=$Week;used=(100-$Week);resetsAt=$WeekReset}
  return $snapshot
}
$state=New-State
Update-QuotaStepState $state (Pair 47 67) 1000
Update-QuotaStepState $state (Pair 44 66) 1000
Assert ($state.windows['300'].pending -and !$state.windows['10080'].pending) 'A five-hour drop must not consume the weekly threshold'
Acknowledge $state
Update-QuotaStepState $state (Pair 44 64) 1000
Assert ($state.windows['10080'].pending -and !$state.windows['300'].pending) 'A weekly drop must trigger independently'
Acknowledge $state
Update-QuotaStepState $state (Pair 39 59) 1000
Assert ($state.pending -and @($state.windows.Values|Where-Object{$_.pending}).Count-eq 2) 'Both windows may cross in the same update'
Acknowledge $state
Update-QuotaStepState $state (Pair 100 54 3000) 1000
Assert (!$state.windows['300'].pending -and $state.windows['10080'].pending) 'A five-hour reset must not suppress a weekly crossing'
Acknowledge $state
Update-QuotaStepState $state (Pair 95 100 3000 5000) 1000
Assert ($state.windows['300'].pending -and !$state.windows['10080'].pending) 'A weekly reset must not suppress a five-hour crossing'

$script:quotaStepReminderState=New-State
Update-QuotaStepState $script:quotaStepReminderState (Pair 47 67) 1000
Update-QuotaStepState $script:quotaStepReminderState (Pair 44 64) 1000
$script:quotaStepReminderEnabled=$true
$script:status=Snapshot 44
$script:window=@{IsVisible=$true};$script:context=@{IsOpen=$false}
$script:collapsed=$true;$script:bubbleMode='quota';$script:drag=$null;$script:settingsSizePreview=$false
$script:completionPending=$false;$script:completionTemporary=$null;$script:closeTimer=$null
$script:opened=0
function Test-WidgetUpdateEditor {return $false}
function Open-WidgetBubble([string]$Mode){Assert ($Mode-eq 'quota') 'Reminder must show quota';$script:opened++}
Tick-QuotaStepReminder $false
Assert ($script:opened-eq 0 -and $script:quotaStepReminderState.pending) 'Hidden widgets must defer the reminder'
$script:context.IsOpen=$true
Tick-QuotaStepReminder $true
Assert ($script:opened-eq 0) 'An open menu must defer the reminder'
$script:context.IsOpen=$false;$script:collapsed=$false;$script:bubbleMode='quote'
Tick-QuotaStepReminder $true
Assert ($script:opened-eq 0) 'A displayed quote must not be interrupted'
$script:collapsed=$true
Tick-QuotaStepReminder $true
Tick-QuotaStepReminder $true
Assert ($script:opened-eq 1 -and $script:quotaStepReminderState.displayCount-eq 1 -and !$script:quotaStepReminderState.pending) 'Deferred reminder must display only once'
Assert (@($script:quotaStepReminderState.windows.Values|Where-Object{$_.pending}).Count-eq 0) 'One popup must acknowledge both pending windows'
$script:quotaStepReminderEnabled=$false;$script:quotaStepReminderState.pending=$true
Tick-QuotaStepReminder $true
Assert ($script:opened-eq 1) 'Disabled setting must suppress reminders'
$settingsFile=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-quota-reminder-'+[Guid]::NewGuid().ToString('N')+'.json')
try{
  $script:status=Snapshot 44 ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600)
  Set-QuotaStepReminderEnabled $true
  $saved=Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8|ConvertFrom-Json
  Assert ($saved.quotaStepReminder-eq $true -and !$script:quotaStepReminderState.pending -and $script:quotaStepReminderState.windows.Count-eq 1) 'Enabling must persist and establish a baseline without a popup'
  Set-QuotaStepReminderEnabled $false
  $saved=Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8|ConvertFrom-Json
  Assert ($saved.quotaStepReminder-eq $false) 'Disabling must persist'
}finally{
  foreach($file in @($settingsFile,($settingsFile+'.bak'))){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file}}
}

foreach($minutes in @(300,10080)){
  Assert ((Get-QuotaBarColor @{minutes=$minutes;remaining=9.9;used=90.1} $false)-eq '#DC2626') 'Below ten percent must be red'
  Assert ((Get-QuotaBarColor @{minutes=$minutes;remaining=10;used=90} $false)-ne '#DC2626') 'Exactly ten percent must retain the existing colour'
  Assert ((Get-QuotaBarColor @{minutes=$minutes;remaining=0;used=100} $false)-eq '#DC2626') 'Zero remaining must use the low-quota colour'
  Assert ((Get-QuotaBarColor @{minutes=$minutes;remaining=5;used=95} $true)-eq '#B3A7C0') 'Expired data must remain unavailable grey'
}
Assert ((Get-QuotaBarColor @{minutes=1440;remaining=5;used=95} $false)-eq '#D77659') 'Other quota windows must retain their existing colour'

Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$script:ui=@{ShortLeft=[Windows.Controls.TextBlock]::new();ShortBar=[Windows.Controls.Border]::new()}
$script:widgetColors=@{original=@();halo=[Windows.Controls.Border]::new();tint=[Windows.Controls.Border]::new();brushes=@{accent=[Windows.Media.Brushes]::Blue;surface=[Windows.Media.Brushes]::White;ink=[Windows.Media.Brushes]::Black}}
$script:testQuota=@{minutes=300;remaining=5;used=95}
function Get-QuotaRows {return @{prefix='Short';window=$script:testQuota}}
function Set-WidgetColorAnimation($Enabled){}
Restore-WidgetOriginalColors
Assert ($script:ui.ShortBar.Background.Color.ToString()-eq '#FFDC2626') 'Restoring theme colours must preserve low-quota red'
function Get-WidgetColorScope($Text){return 'full'}
function Set-WidgetColorPalette($Palette){}
$script:colorMode='rainbow';$script:bubbleMode='quota';$script:widgetMusic=$null
foreach($name in @('BubbleShape','Tail','TailNear')){$script:ui[$name]=[Windows.Shapes.Rectangle]::new()}
foreach($name in @('Header','QuoteText','Refresh','MenuButton')){$script:ui[$name]=[Windows.Controls.Label]::new()}
Update-WidgetColorScene
Assert ($script:ui.ShortBar.Background.Color.ToString()-eq '#FFDC2626') 'Rainbow theme must not overwrite low-quota red'
Write-Output ("PASS: $checks quota threshold, settings, deferred popup and WPF colour assertions")
