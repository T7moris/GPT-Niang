# Only current, successful official snapshots can change the quota mood.
$script:quotaActualMood='normal';$script:quotaPreview=$false
function Get-WidgetQuotaMood($Status,[long]$NowMs=([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())) {
  if(!$Status -or $Status.ok-ne $true -or $Status.queryOk-ne $true){return 'unknown'}
  if($null-eq $Status.observedAt){return 'unknown'}
  try{$age=$NowMs-[double]$Status.observedAt}catch{return 'unknown'}
  if([double]::IsNaN($age) -or [double]::IsInfinity($age) -or $age-lt 0 -or $age-gt 180000){return 'unknown'}
  $valid=0;$uncertain=$false
  foreach($window in @($Status.windows)){
    if(!$window -or $window.kind-eq 'individual' -or $window.minutes-notin @(300,10080)){continue}
    if($null-eq $window.remaining){$uncertain=$true;continue}
    try{$remaining=[double]$window.remaining}catch{$uncertain=$true;continue}
    if([double]::IsNaN($remaining) -or [double]::IsInfinity($remaining) -or $remaining-lt 0 -or $remaining-gt 100){$uncertain=$true;continue}
    if($null-ne $window.resetsAt){
      try{$reset=[double]$window.resetsAt}catch{$uncertain=$true;continue}
      if([double]::IsNaN($reset) -or [double]::IsInfinity($reset) -or $reset-le [Math]::Floor($NowMs/1000)){$uncertain=$true;continue}
    }
    $valid++
    if($remaining-le 5){return 'low'}
  }
  if(!$uncertain){return 'normal'}
  return 'unknown'
}

function Update-WidgetQuotaMood {
  $detected=Get-WidgetQuotaMood $script:status
  $account=[string]$script:status.accountKey
  # A missing/unreadable file does not prove that the login changed.
  $changedAccount=![string]::IsNullOrWhiteSpace($account) -and $account-ne $script:quotaMoodAccount
  # Keep the last pose on a temporary failure, but never carry it to another login.
  if($changedAccount){$script:quotaMoodAccount=$account;$script:quotaActualMood='normal'}
  if($script:status.clearPrevious-eq $true -and $script:status.queryOk-ne $true){$script:quotaActualMood='normal'}
  if($detected-ne 'unknown'){$script:quotaActualMood=$detected}
  $next=if($script:quotaPreview){'low'}else{$script:quotaActualMood}
  if($next-eq $script:quotaMood){return}
  $previous=$script:quotaMood;$script:quotaMood=$next
  try{$null=Set-WidgetQuotaCharacter $next}
  catch{$script:quotaMood=$previous;throw}
  if($script:bubbleMode-eq 'quote'){
    $script:ui.QuoteText.Text=Get-WidgetBubbleQuote $script:dataDir
    Fit-QuoteText;Apply-Scene
  }
}

function Set-WidgetQuotaPreview([bool]$Enabled) {
  $script:quotaPreview=$Enabled
  Update-WidgetQuotaMood
  if($script:settingsMenuUi){Update-WidgetSettingsMenu}
}
