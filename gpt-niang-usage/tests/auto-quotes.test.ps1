param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
$appDir=Split-Path $TestRoot -Parent
. (Join-Path $appDir 'runtime\quotes.ps1')
$source=[IO.File]::ReadAllText((Join-Path $appDir 'widget.ps1'),[Text.Encoding]::UTF8)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($name in @('Tick-WidgetAutoQuote','Write-WidgetJson','Save-Settings')){
  $definition=$ast.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq $name},$true)
  . ([ScriptBlock]::Create($definition.Extent.Text))
}
function Assert($condition,[string]$message){if(!$condition){throw $message}}
function Assert-Invalid([string]$Value,[string]$Unit='秒'){
  $failed=$false;try{$null=ConvertTo-WidgetAutoQuoteSeconds $Value $Unit}catch{$failed=$true}
  Assert $failed ('Expected invalid interval: '+$Value+' '+$Unit)
}
$testDir=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-auto-quotes-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testDir
$settingsFile=Join-Path $testDir 'settings.json'
try{
  Assert ((ConvertTo-WidgetAutoQuoteSeconds '1.5' '分钟')-eq 90) 'Decimal minutes convert to seconds'
  Assert ((ConvertTo-WidgetAutoQuoteSeconds '0.5' '小时')-eq 1800) 'Hours convert to seconds'
  foreach($value in @('', 'text','NaN','Infinity','-1','0','9','86401')){Assert-Invalid $value}
  Assert-Invalid '1' 'days'
  Initialize-WidgetAutoQuoteSettings $null
  Assert (!$script:autoQuoteEnabled -and $script:autoQuoteIntervalSeconds-eq 300) 'Existing preferences default to disabled'
  Assert (!(Test-WidgetAutoQuoteDue 10000 $true $false)) 'Disabled never fires'
  Set-WidgetAutoQuoteSettings $true 10
  $saved=Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8|ConvertFrom-Json
  Initialize-WidgetAutoQuoteSettings $saved
  Assert ($script:autoQuoteEnabled -and $script:autoQuoteIntervalSeconds-eq 10) 'Actual widget settings survive reload'
  Assert (!(Test-WidgetAutoQuoteDue 1000 $true $false)) 'First idle tick schedules, rather than showing immediately'
  Assert (!(Test-WidgetAutoQuoteDue 10999 $true $false)) 'Never fires before the interval'
  Assert (Test-WidgetAutoQuoteDue 11000 $true $false) 'Fires at the interval'
  Assert (!(Test-WidgetAutoQuoteDue 11000 $true $false)) 'One display per deadline'
  Assert (!(Test-WidgetAutoQuoteDue 21000 $false $false)) 'Hidden widgets do not display quotes'
  Assert (!(Test-WidgetAutoQuoteDue 30000 $true $false)) 'Resume cannot catch up immediately'
  Assert (!(Test-WidgetAutoQuoteDue 31000 $true $true)) 'Active bubble, menu or drag defers a due quote'
  Assert (!(Test-WidgetAutoQuoteDue 40999 $true $false)) 'Waits full interval after interaction'
  Assert (Test-WidgetAutoQuoteDue 41000 $true $false) 'Resumes after interaction'
  Assert (Test-WidgetAutoQuoteDue 90000 $true $false) 'Long delay shows just one quote'
  Assert (!(Test-WidgetAutoQuoteDue 90000 $true $false)) 'Delayed ticks do not create a burst'
  $script:collapsed=$true;$script:drag=$null;$script:context=@{IsOpen=$false};$script:editorOpen=$false;$script:shown=0;$script:switched=0
  function Test-WidgetUpdateEditor {return $script:editorOpen}
  function Show-Quota {$script:collapsed=$false;$script:shown++}
  function Switch-Scene([string]$Mode) {$script:bubbleMode=$Mode;$script:switched++}
  Reset-WidgetAutoQuoteSchedule 0
  Tick-WidgetAutoQuote 10000 $true
  Assert ($script:shown-eq 1 -and $script:switched-eq 1 -and $script:bubbleMode-eq 'quote') 'Actual tick opens a quote scene'
  Tick-WidgetAutoQuote 20000 $true
  Assert ($script:shown-eq 1) 'Actual tick cannot replace an open bubble'
  $script:collapsed=$true;$script:editorOpen=$true
  Tick-WidgetAutoQuote 30000 $true
  Assert ($script:shown-eq 1) 'Editor prevents automatic display'
  $script:editorOpen=$false;$script:drag=@{moved=$true}
  Tick-WidgetAutoQuote 40000 $true
  Assert ($script:shown-eq 1) 'Dragging prevents automatic display'
  $script:drag=$null;$script:context.IsOpen=$true
  Tick-WidgetAutoQuote 50000 $true
  Assert ($script:shown-eq 1) 'Menu prevents automatic display'
  Set-WidgetAutoQuoteSettings $false 90
  Initialize-WidgetAutoQuoteSettings (Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8|ConvertFrom-Json)
  Assert (!$script:autoQuoteEnabled -and $script:autoQuoteIntervalSeconds-eq 90) 'Disabling retains selected interval'
  Assert (!(Test-WidgetAutoQuoteDue 999999 $true $false)) 'Disabled state remains effective after reload'
  Initialize-WidgetAutoQuoteSettings @{autoQuoteEnabled='false';autoQuoteIntervalSeconds=-1}
  Assert (!$script:autoQuoteEnabled -and $script:autoQuoteIntervalSeconds-eq 300) 'Malformed settings safely default'
  Write-Output 'PASS: automatic quote conversion, settings persistence, exact deadlines, visibility, interaction deferral and no bursts'
}finally{
  if([IO.Path]::GetFullPath($testDir).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $testDir -Recurse -Force}
}
