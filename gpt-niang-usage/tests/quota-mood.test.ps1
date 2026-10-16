param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$script:appDir=Split-Path $TestRoot -Parent
foreach($module in @('quota-mood.ps1','quota-character.ps1','quote-layout.ps1','color-theme.ps1')){
  . ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir ('runtime\'+$module)),[Text.Encoding]::UTF8)))
}
. (Join-Path $script:appDir 'runtime\quotes.ps1')
function Assert-Equal($Actual,$Expected,[string]$Message){if($Actual-cne $Expected){throw "$Message : expected '$Expected', got '$Actual'"}}
$now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();$future=[Math]::Floor($now/1000)+3600
function New-Snapshot($Short=50,$Week=80,[string]$Account='test-a'){
  [pscustomobject]@{ok=$true;queryOk=$true;observedAt=$now;accountKey=$Account;windows=@(
    [pscustomobject]@{minutes=300;remaining=$Short;used=100-$Short;resetsAt=$future},
    [pscustomobject]@{minutes=10080;remaining=$Week;used=100-$Week;resetsAt=$future})}
}
$cases=@(
  @{name='healthy';status=(New-Snapshot 50 80);want='normal'},
  @{name='5h zero';status=(New-Snapshot 0 80);want='low'},
  @{name='week zero';status=(New-Snapshot 50 0);want='low'},
  @{name='5h low';status=(New-Snapshot 4.99 80);want='low'},
  @{name='week low';status=(New-Snapshot 50 4);want='low'},
  @{name='both low';status=(New-Snapshot 1 2);want='low'},
  @{name='exactly five';status=(New-Snapshot 5 5);want='low'},
  @{name='exactly five in 5h only';status=(New-Snapshot 5 80);want='low'},
  @{name='exactly five in week only';status=(New-Snapshot 80 5);want='low'},
  @{name='above five';status=(New-Snapshot 5.01 5.01);want='normal'},
  @{name='old threshold does not trigger';status=(New-Snapshot 9.99 80);want='normal'},
  @{name='5h recovered but week low';status=(New-Snapshot 100 4);want='low'},
  @{name='week recovered but 5h low';status=(New-Snapshot 4 100);want='low'},
  @{name='no data';status=$null;want='unknown'}
)
$failed=New-Snapshot 0 0;$failed.queryOk=$false;$cases+=@{name='failed refresh';status=$failed;want='unknown'}
$stale=New-Snapshot 0 0;$stale.observedAt=$now-180001;$cases+=@{name='stale data';status=$stale;want='unknown'}
$futureData=New-Snapshot 0 0;$futureData.observedAt=$now+1000;$cases+=@{name='future observation';status=$futureData;want='unknown'}
$expired=New-Snapshot 0 80;$expired.windows[0].resetsAt=[Math]::Floor($now/1000)-1;$cases+=@{name='expired window';status=$expired;want='unknown'}
$missing=New-Snapshot 50 80;$missing.windows[0].remaining=$null;$cases+=@{name='missing is not zero';status=$missing;want='unknown'}
$invalid=New-Snapshot 50 80;$invalid.windows[0].remaining=[double]::NaN;$cases+=@{name='NaN is not zero';status=$invalid;want='unknown'}
$negative=New-Snapshot 50 80;$negative.windows[0].remaining=-1;$cases+=@{name='negative invalid';status=$negative;want='unknown'}
$noReset=New-Snapshot 0 80;$noReset.windows[0].resetsAt=$null;$cases+=@{name='no reset but known remaining';status=$noReset;want='low'}
$weekOnly=New-Snapshot 50 0;$weekOnly.windows=@($weekOnly.windows[1]);$cases+=@{name='weekly-only';status=$weekOnly;want='low'}
$other=New-Snapshot 50 80;$other.windows=@([pscustomobject]@{minutes=43200;remaining=0});$cases+=@{name='other windows ignored';status=$other;want='normal'}
$individual=New-Snapshot 50 80;$individual.windows+=@([pscustomobject]@{kind='individual';remaining=0});$cases+=@{name='individual ignored';status=$individual;want='normal'}
foreach($case in $cases){Assert-Equal (Get-WidgetQuotaMood $case.status $now) $case.want $case.name}
Write-Output ('PASS: '+$cases.Count+' quota boundaries, invalid snapshots, expiry and window selection')

$script:dataDir=Join-Path $TestRoot ('quota-fixture-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($script:dataDir)
$source=[IO.File]::ReadAllText((Join-Path $script:appDir 'widget.ps1'),[Text.Encoding]::UTF8)
$tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw ($parseErrors|Out-String)}
$script:window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $script:appDir 'widget.xaml'),[Text.Encoding]::UTF8))
$script:ui=@{};foreach($name in @('Girl','QuoteText','SceneText')){$script:ui[$name]=$script:window.FindName($name)}
$script:quotaMood='normal';$script:quotaMoodAccount='test-a';$script:characterId='gpt-dragon';$script:bubbleMode='quota';$script:sceneRevision=1
Initialize-WidgetQuoteLayouts $script:appDir
function Save-Settings {throw 'Automatic mood must not overwrite preferred character settings'}
function Apply-Scene {Set-WidgetSceneLayout}
try{
  Set-WidgetQuotaCharacter 'normal';$normalImage=$script:ui.Girl.Source
  $script:status=New-Snapshot 0 80;Update-WidgetQuotaMood
  Assert-Equal $script:quotaMood 'low' 'Low snapshot changes mood'
  Assert-Equal $script:quotaCharacterState 'low' 'Real image switches'
  Assert-Equal $script:characterId 'gpt-dragon' 'Preferred ID remains unchanged'
  Assert-Equal $script:bitmap.PixelWidth 1254 'Low sprite width'
  Assert-Equal $script:bitmap.PixelHeight 1254 'Low sprite height'
  Assert-Equal $script:ui.Girl.Width 228 'Low sprite uses the selected visual size'
  Assert-Equal ([Windows.Controls.Canvas]::GetTop($script:ui.Girl)) 129 'Low boots align with normal bottom'
  Assert-Equal ([object]::ReferenceEquals($script:ui.Girl.Source,$normalImage)) $false 'Girl source actually changed'
  Assert-Equal $script:alphaPixels.Length (1254*1254*4) 'Hit-test alpha map changes with sprite'
  $lowImage=$script:ui.Girl.Source;Update-WidgetQuotaMood
  Assert-Equal ([object]::ReferenceEquals($script:ui.Girl.Source,$lowImage)) $true 'Unchanged mood does not repeatedly decode'
  $script:status=New-Snapshot 100 4;Update-WidgetQuotaMood
  Assert-Equal $script:quotaMood 'low' '5h recovery cannot override a low weekly window'
  $script:status=New-Snapshot 4 100;Update-WidgetQuotaMood
  Assert-Equal $script:quotaMood 'low' 'Weekly recovery cannot override a low 5h window'
  $custom=Save-WidgetQuotes $script:dataDir @('正常自定义台词')
  $pool=@(Read-WidgetQuoteFile (Join-Path $script:appDir 'assets\quotes-low-quota.json')).text
  $last='';for($i=0;$i-lt 100;$i++){
    $quote=Get-WidgetBubbleQuote $script:dataDir
    if($quote-notin $pool -or $quote-eq $last){throw 'Low mood mixed quote pools or immediately repeated'};$last=$quote
  }
  $script:bubbleMode='quote';$script:ui.QuoteText.Text=$last;Fit-QuoteText
  $script:status=New-Snapshot 5.01 5.01;Update-WidgetQuotaMood
  Assert-Equal $script:quotaMood 'normal' 'Fresh recovery requires both windows above five percent'
  Assert-Equal $script:quotaCharacterState 'normal' 'Original image restored'
  Assert-Equal $script:ui.Girl.Width 208 'Recovery restores normal visual size'
  Assert-Equal ([Windows.Controls.Canvas]::GetTop($script:ui.Girl)) 142 'Recovery restores normal position'
  Assert-Equal $script:ui.QuoteText.Tag '正常自定义台词' 'Open bubble changes back to normal independent pool'
  $script:status=New-Snapshot 50 0;Update-WidgetQuotaMood
  if($script:ui.QuoteText.Tag-notin $pool){throw 'Open quote bubble did not switch to low pool'}
  $script:status.queryOk=$false;Update-WidgetQuotaMood
  Assert-Equal $script:quotaMood 'low' 'Failure holds known mood'
  $script:status=[pscustomobject]@{ok=$false;queryOk=$false;accountKey='test-b';windows=@()};Update-WidgetQuotaMood
  Assert-Equal $script:quotaMood 'normal' 'Account switch clears previous low mood'
  $before=[IO.File]::ReadAllText((Join-Path $script:dataDir 'quotes.json'))
  Assert-Equal (Get-WidgetQuote $script:dataDir) '正常自定义台词' 'Normal custom quotes retained'
  Assert-Equal ([IO.File]::ReadAllText((Join-Path $script:dataDir 'quotes.json'))) $before 'Low pool never writes normal custom quotes'
  $script:status=New-Snapshot 100 100;Set-WidgetQuotaPreview $true
  Assert-Equal $script:quotaMood 'low' 'Preview forces low pose despite healthy quota'
  Update-WidgetQuotaMood
  Assert-Equal $script:quotaMood 'low' 'Automatic refresh cannot cancel preview'
  $script:status=New-Snapshot 100 5;Update-WidgetQuotaMood
  Assert-Equal $script:quotaActualMood 'low' 'Automatic detection remains active during preview'
  $script:status=New-Snapshot 100 100;Update-WidgetQuotaMood
  Assert-Equal $script:quotaActualMood 'normal' 'Automatic recovery is still tracked during preview'
  Set-WidgetQuotaPreview $false
  Assert-Equal $script:quotaMood 'normal' 'Ending preview restores actual healthy mood'
  $script:status=New-Snapshot 100 5;Set-WidgetQuotaPreview $true;Set-WidgetQuotaPreview $false
  Assert-Equal $script:quotaMood 'low' 'Ending preview retains genuine low weekly quota'
  $script:status=New-Snapshot 5 100;Update-WidgetQuotaMood
  Assert-Equal $script:quotaMood 'low' 'Five-hour quota at exactly five keeps automatic low mood'
  $script:status=New-Snapshot 100 100;Update-WidgetQuotaMood
  Assert-Equal $script:quotaMood 'normal' 'Automatic recovery still works after a user preview'
  Write-Output 'PASS: real WPF source, alpha hit map, no repeated decoding, preference retention, independent quotes, live bubble recovery and account isolation'
}finally{
  $script:window.Close()
  $resolved=[IO.Path]::GetFullPath($script:dataDir);$allowed=[IO.Path]::GetFullPath($TestRoot).TrimEnd('\')+'\'
  if(!$resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture path'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
