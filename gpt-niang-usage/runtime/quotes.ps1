# Bundled local quotes; attribution is in assets/quotes-LICENSE.txt. No network or account data is used.
$script:widgetQuotesBuiltInPath=Join-Path $PSScriptRoot '..\assets\quotes.json'
$script:widgetQuoteRandom=New-Object System.Random
$script:widgetQuoteLastByDataDir=@{}

function ConvertTo-WidgetQuoteRows($Value) {
  if($null-eq $Value){return}
  if($Value -isnot [string] -and $Value.PSObject.Properties['quotes']){$Value=$Value.quotes}
  $rows=New-Object 'System.Collections.Generic.List[object]'
  $index=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
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
    if($index.ContainsKey($text)){$index[$text].weight=[Math]::Min(1000.0,$index[$text].weight+$weight)}
    else{$row=[pscustomobject]@{text=$text;weight=$weight};$index[$text]=$row;$rows.Add($row)}
  }
  foreach($row in $rows){$row}
}

function Read-WidgetQuoteFile([string]$Path) {
  # Bound the parse cost: the editor can write a large text dump, and this
  # file is re-read whenever a quote is displayed.
  if(([IO.FileInfo]::new($Path)).Length-gt 1MB){throw '语录文件超过 1 MB，请精简后重试。'}
  $json=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
  $rows=@(ConvertTo-WidgetQuoteRows $json)
  if($rows.Count-gt 5000){throw '语录条数超过 5000，请精简后重试。'}
  $rows
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


# Automatic quotes use the existing widget loop and the same local quote pool.
$script:autoQuoteEnabled=$false;$script:autoQuoteIntervalSeconds=300
$script:autoQuoteNextAt=0;$script:autoQuoteLastTickAt=0;$script:autoQuoteWasEligible=$false;$script:autoQuoteDisplayCount=0

function Initialize-WidgetAutoQuoteSettings($Settings) {
  $script:autoQuoteEnabled=$false;$script:autoQuoteIntervalSeconds=300
  $script:autoQuoteNextAt=0;$script:autoQuoteLastTickAt=0;$script:autoQuoteWasEligible=$false;$script:autoQuoteDisplayCount=0
  if($Settings.autoQuoteEnabled-is [bool]){$script:autoQuoteEnabled=$Settings.autoQuoteEnabled}
  try{
    $seconds=[double]$Settings.autoQuoteIntervalSeconds
    if(@(60,300,900)-contains $seconds){$script:autoQuoteIntervalSeconds=[int]$seconds}
  }catch{}
}

function Reset-WidgetAutoQuoteSchedule([long]$Now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) {
  $script:autoQuoteNextAt=if($script:autoQuoteEnabled){$Now+[long]$script:autoQuoteIntervalSeconds*1000}else{0}
  $script:autoQuoteLastTickAt=$Now;$script:autoQuoteWasEligible=$false
}

function Set-WidgetAutoQuoteSettings([bool]$Enabled,[int]$Seconds) {
  if(@(60,300,900)-notcontains $Seconds){throw '请选择 1、5 或 15 分钟。'}
  $script:autoQuoteEnabled=$Enabled;$script:autoQuoteIntervalSeconds=$Seconds
  Reset-WidgetAutoQuoteSchedule
  Save-Settings
}

function Test-WidgetAutoQuoteDue([long]$Now,[bool]$Visible,[bool]$Busy) {
  # Restart on resume, time changes, or transitions out of a hidden/busy state.
  $gap=$Now-$script:autoQuoteLastTickAt
  $restart=$script:autoQuoteLastTickAt-le 0 -or !$script:autoQuoteWasEligible -or $gap-lt 0 -or $gap-gt 5000
  if(!$script:autoQuoteEnabled -or !$Visible -or $Busy){Reset-WidgetAutoQuoteSchedule $Now;return $false}
  if($restart){Reset-WidgetAutoQuoteSchedule $Now;$script:autoQuoteWasEligible=$true;return $false}
  $script:autoQuoteLastTickAt=$Now
  if($Now-lt $script:autoQuoteNextAt){return $false}
  $script:autoQuoteNextAt=$Now+[long]$script:autoQuoteIntervalSeconds*1000
  return $true
}
