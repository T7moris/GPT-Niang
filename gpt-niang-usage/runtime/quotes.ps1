# Bundled local quotes; attribution is in assets/quotes-LICENSE.txt. No network or account data is used.
$script:widgetQuotesBuiltInPath=Join-Path $PSScriptRoot '..\assets\quotes.json'
$script:widgetQuoteRandom=New-Object System.Random
$script:widgetQuoteLastByDataDir=@{}
$script:autoQuoteEnabled=$false;$script:autoQuoteIntervalSeconds=300;$script:autoQuoteNextAt=0;$script:autoQuoteDisplayCount=0

function ConvertTo-WidgetQuoteRows($Value) {
  if($null-eq $Value){return}
  if($Value -isnot [string] -and $Value.PSObject.Properties['quotes']){$Value=$Value.quotes}
  $rows=New-Object 'System.Collections.Generic.List[object]'
  foreach($entry in @($Value)){
    $text=$null;$weight=1.0
    if($entry -is [string]){$text=$entry}
    elseif($entry -is [Collections.IDictionary]){
      $text=$entry['text']
      if($entry.Contains('weight')){try{$weight=[double]$entry['weight']}catch{continue}}
    }elseif($null-ne $entry -and $entry.PSObject.Properties['text']){
      $text=$entry.text
      if($entry.PSObject.Properties['weight']){try{$weight=[double]$entry.weight}catch{continue}}
    }
    if($text -isnot [string]){continue}
    $text=$text.Trim()
    if(!$text -or $text.Length-gt 200 -or $text-match '[\x00-\x08\x0B\x0C\x0E-\x1F]'){continue}
    if([double]::IsNaN($weight) -or [double]::IsInfinity($weight) -or $weight-le 0 -or $weight-gt 1000){continue}
    $duplicate=$null
    foreach($row in $rows){if([string]::Equals($row.text,$text,[StringComparison]::Ordinal)){$duplicate=$row;break}}
    if($duplicate){$duplicate.weight=[Math]::Min(1000.0,$duplicate.weight+$weight)}
    else{$rows.Add([pscustomobject]@{text=$text;weight=$weight})}
  }
  foreach($row in $rows){$row}
}

function Read-WidgetQuoteFile([string]$Path) {
  $json=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
  @(ConvertTo-WidgetQuoteRows $json)
}

function Get-WidgetQuoteSettings([string]$DataDir) {
  $customPath=Join-Path $DataDir 'quotes.json'
  $rows=@();$problem=$null;$source='built-in'
  if([IO.File]::Exists($customPath)){
    try{
      $rows=@(Read-WidgetQuoteFile $customPath)
      if($rows.Count-gt 0){$source='custom'}else{$problem='自定义语录没有有效条目，已使用内置语录。'}
    }catch{$problem='自定义语录无法读取，已使用内置语录。'}
  }
  if($rows.Count-eq 0){
    try{$rows=@(Read-WidgetQuoteFile $script:widgetQuotesBuiltInPath)}catch{$rows=@()}
  }
  if($rows.Count-eq 0){
    $source='fallback'
    $rows=@([pscustomobject]@{text='Ciallo～ 今天也请多关照。';weight=1.0},[pscustomobject]@{text='我在这儿，慢慢来就好。';weight=1.0})
  }
  [pscustomobject]@{source=$source;quotes=@($rows);customPath=$customPath;error=$problem}
}

function Get-WidgetQuote([string]$DataDir) {
  $settings=Get-WidgetQuoteSettings $DataDir
  $key=[IO.Path]::GetFullPath($DataDir)
  $last=$script:widgetQuoteLastByDataDir[$key]
  $candidates=@($settings.quotes | Where-Object {![string]::Equals($_.text,$last,[StringComparison]::Ordinal)})
  if($candidates.Count-eq 0){$candidates=@($settings.quotes)}
  $total=0.0;foreach($entry in $candidates){$total+=$entry.weight}
  $draw=$script:widgetQuoteRandom.NextDouble()*$total
  $choice=$candidates[$candidates.Count-1]
  foreach($entry in $candidates){$draw-=$entry.weight;if($draw-lt 0){$choice=$entry;break}}
  $script:widgetQuoteLastByDataDir[$key]=$choice.text
  [string]$choice.text
}

function Save-WidgetQuotes([string]$DataDir,$Quotes) {
  $rows=@(ConvertTo-WidgetQuoteRows $Quotes)
  if($rows.Count-eq 0){throw '请至少填写一条有效语录；每条最多 200 字，权重须大于 0 且不超过 1000。'}
  $null=[IO.Directory]::CreateDirectory($DataDir)
  $file=Join-Path $DataDir 'quotes.json'
  $temp=$file+'.'+$PID+'.tmp'
  try{
    $json=@{version=1;quotes=@($rows)} | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($temp,$json,[Text.UTF8Encoding]::new($true))
    if([IO.File]::Exists($file)){[IO.File]::Replace($temp,$file,($file+'.bak'),$true)}else{[IO.File]::Move($temp,$file)}
  }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
  Get-WidgetQuoteSettings $DataDir
}

function Reset-WidgetQuotes([string]$DataDir) {
  $file=Join-Path $DataDir 'quotes.json'
  if([IO.File]::Exists($file)){
    [IO.File]::Copy($file,($file+'.bak'),$true)
    [IO.File]::Delete($file)
  }
  Get-WidgetQuoteSettings $DataDir
}

function ConvertTo-WidgetAutoQuoteSeconds([string]$Value,[string]$Unit='秒') {
  $number=0.0
  if(![double]::TryParse($Value.Trim(),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -or [double]::IsNaN($number) -or [double]::IsInfinity($number)){throw '请输入有效的数字，例如 30 或 1.5。'}
  $multiplier=switch($Unit){'秒'{1};'分钟'{60};'小时'{3600};default{throw '请选择秒、分钟或小时。'}}
  $seconds=$number*$multiplier
  if($seconds-lt 10 -or $seconds-gt 86400){throw '间隔须在 10 秒至 24 小时之间。'}
  [int][Math]::Round($seconds)
}

function Initialize-WidgetAutoQuoteSettings($Settings) {
  $script:autoQuoteEnabled=$false;$script:autoQuoteIntervalSeconds=300;$script:autoQuoteNextAt=0
  if($Settings.autoQuoteEnabled-is [bool]){$script:autoQuoteEnabled=$Settings.autoQuoteEnabled}
  if($null-ne $Settings.autoQuoteIntervalSeconds){
    try{$script:autoQuoteIntervalSeconds=ConvertTo-WidgetAutoQuoteSeconds ([string]$Settings.autoQuoteIntervalSeconds)}catch{}
  }
}

function Reset-WidgetAutoQuoteSchedule([long]$Now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) {
  $script:autoQuoteNextAt=if($script:autoQuoteEnabled){$Now+[long]$script:autoQuoteIntervalSeconds*1000}else{0}
}

function Set-WidgetAutoQuoteSettings([bool]$Enabled,[int]$Seconds) {
  $seconds=ConvertTo-WidgetAutoQuoteSeconds ([string]$Seconds)
  $script:autoQuoteEnabled=$Enabled;$script:autoQuoteIntervalSeconds=$seconds
  Reset-WidgetAutoQuoteSchedule
  Save-Settings
}

function Test-WidgetAutoQuoteDue([long]$Now,[bool]$Visible,[bool]$Busy) {
  # Count idle time only; hiding or interacting restarts the interval, with no catch-up burst.
  if(!$script:autoQuoteEnabled -or !$Visible -or $Busy){Reset-WidgetAutoQuoteSchedule $Now;return $false}
  if($script:autoQuoteNextAt-le 0){Reset-WidgetAutoQuoteSchedule $Now;return $false}
  if($Now-lt $script:autoQuoteNextAt){return $false}
  Reset-WidgetAutoQuoteSchedule $Now
  return $true
}

function Get-WidgetAutoQuoteIntervalLabel([int]$Seconds) {
  if($Seconds%3600-eq 0){return ([string]($Seconds/3600))+' 小时'}
  if($Seconds%60-eq 0){return ([string]($Seconds/60))+' 分钟'}
  ([string]$Seconds)+' 秒'
}
