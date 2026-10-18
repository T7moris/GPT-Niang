# Local selection and history; attribution is in assets/quotes-LICENSE.txt. Optional generation runs in the worker.
$script:widgetQuotesBuiltInPath=Join-Path $PSScriptRoot '..\assets\quotes.json'
$script:widgetQuoteRandom=New-Object System.Random
$script:widgetQuoteLastByDataDir=@{}

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
    else{$preferred=$false;if($entry -is [Collections.IDictionary]){$preferred=$entry['preferred']-eq $true}elseif($entry.PSObject.Properties['preferred']){$preferred=$entry.preferred-eq $true};$rows.Add([pscustomobject]@{text=$text;weight=$weight;preferred=[bool]$preferred})}
  }
  foreach($row in $rows){$row}
}

function Read-WidgetQuoteFile([string]$Path) {
  $json=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
  @(ConvertTo-WidgetQuoteRows $json)
}

function Get-WidgetQuoteSettings([string]$DataDir) {
  $library=Read-WidgetQuoteLibrary $DataDir
  if($null-ne $library){return [pscustomobject]@{source='library';quotes=@($library.base);customPath=(Join-Path $DataDir 'quote-library.json');error=$null}}
  $customPath=Join-Path $DataDir 'quotes.json'
  $rows=@();$problem=$null;$source='built-in'
  if([IO.File]::Exists($customPath)){
    try{
      $rows=@(Read-WidgetQuoteFile $customPath)
      $source='custom'
    }catch{$problem='自定义语录无法读取，已使用内置语录。'}
  }
  if($rows.Count-eq 0 -and $source-ne 'custom'){
    try{$rows=@(Read-WidgetQuoteFile $script:widgetQuotesBuiltInPath)}catch{$rows=@()}
  }
  if($rows.Count-eq 0 -and $source-ne 'custom'){
    $source='fallback'
    $rows=@([pscustomobject]@{text='Ciallo～ 今天也请多关照。';weight=1.0},[pscustomobject]@{text='我在这儿，慢慢来就好。';weight=1.0})
  }
  [pscustomobject]@{source=$source;quotes=@($rows);customPath=$customPath;error=$problem}
}

function Get-WidgetQuote([string]$DataDir) {
  $settings=Get-WidgetQuoteSettings $DataDir
  $generation=Get-WidgetGenerationSettings $DataDir
  $rows=@($settings.quotes)
  if($generation.enabled){
    $rows+=@(Get-WidgetGeneratedQuotes $DataDir)
    $seen=@{};$rows=@(foreach($row in $rows){$id=Get-WidgetQuoteKey $row.text;if(!$seen.ContainsKey($id)){$seen[$id]=$true;$row}})
    $history=Read-WidgetQuoteHistory $DataDir
    $unseen=@($rows|Where-Object{!$history.shown.ContainsKey((Get-WidgetQuoteKey $_.text))})
    if($unseen.Count-gt 0){$rows=$unseen}
  }
  if($rows.Count-eq 0){return '语录库存为空，请在“编辑我的语录”中添加。'}
  $rows=@(foreach($row in $rows){[pscustomobject]@{text=$row.text;weight=($row.weight*$(if($row.preferred){3}else{1}))}})
  $key=[IO.Path]::GetFullPath($DataDir)
  $last=$script:widgetQuoteLastByDataDir[$key]
  $candidates=@($rows | Where-Object {![string]::Equals($_.text,$last,[StringComparison]::Ordinal)})
  if($candidates.Count-eq 0){$candidates=$rows}
  $total=0.0;foreach($entry in $candidates){$total+=$entry.weight}
  $draw=$script:widgetQuoteRandom.NextDouble()*$total
  $choice=$candidates[$candidates.Count-1]
  foreach($entry in $candidates){$draw-=$entry.weight;if($draw-lt 0){$choice=$entry;break}}
  $script:widgetQuoteLastByDataDir[$key]=$choice.text
  [string]$choice.text
}

function Get-WidgetQuoteKey([string]$Text) {
  $normalized=$Text.Normalize([Text.NormalizationForm]::FormKC)-replace '\s+',''
  $hash=[Security.Cryptography.SHA256]::Create()
  try{return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
}
function Write-WidgetQuoteJson([string]$Path,$Value) {
  $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
  $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
  try{
    [IO.File]::WriteAllText($temporary,($Value|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    if([IO.File]::Exists($Path)){[IO.File]::Replace($temporary,$Path,($Path+'.bak'),$true)}else{[IO.File]::Move($temporary,$Path)}
  }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
function Read-WidgetQuoteHistory([string]$DataDir) {
  $history=@{version=1;startedAt=[DateTime]::UtcNow.ToString('o');shown=@{}}
  try{
    $saved=[IO.File]::ReadAllText((Join-Path $DataDir 'quote-history.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json
    if($saved.startedAt){$history.startedAt=$saved.startedAt}
    foreach($property in $saved.shown.PSObject.Properties){if($property.Name-match '^[a-f0-9]{64}$'){$history.shown[$property.Name]=[string]$property.Value}}
  }catch{}
  return $history
}
function Initialize-WidgetQuoteHistory([string]$DataDir) {
  if(![IO.File]::Exists((Join-Path $DataDir 'quote-history.json'))){Write-WidgetQuoteJson (Join-Path $DataDir 'quote-history.json') (Read-WidgetQuoteHistory $DataDir)}
}
function Register-WidgetQuoteShown([string]$DataDir,[string]$Text) {
  if(!$Text){return}
  $history=Read-WidgetQuoteHistory $DataDir
  $id=Get-WidgetQuoteKey $Text
  if($history.shown.ContainsKey($id)){return}
  $history.shown[$id]=[DateTime]::UtcNow.ToString('o')
  Write-WidgetQuoteJson (Join-Path $DataDir 'quote-history.json') $history
}
function Get-WidgetGenerationSettings([string]$DataDir) {
  $personaPath=Join-Path (Split-Path $script:widgetQuotesBuiltInPath -Parent) 'quote-persona.txt'
  $persona=if([IO.File]::Exists($personaPath)){[IO.File]::ReadAllText($personaPath,[Text.Encoding]::UTF8).Trim()}else{''}
  $result=@{enabled=$false;threshold=20;batchSize=43;maxDaily=2;minIntervalMinutes=30;model='';persona=$persona;revision=''}
  try{
    $saved=[IO.File]::ReadAllText((Join-Path $DataDir 'quote-generation.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json
    $result.enabled=$saved.enabled-is [bool] -and $saved.enabled
    foreach($spec in @(@('threshold',1,1000),@('batchSize',1,200),@('maxDaily',1,100),@('minIntervalMinutes',1,1440))){
      $value=$saved.($spec[0]);if(($value-is [int] -or $value-is [long]) -and $value-ge $spec[1] -and $value-le $spec[2]){$result[$spec[0]]=[int]$value}
    }
    if($saved.model-is [string] -and $saved.model-match '^[A-Za-z0-9._:/-]{0,160}$'){$result.model=$saved.model}
    if($saved.persona-is [string] -and $saved.persona.Trim() -and $saved.persona.Length-le 6000){$result.persona=$saved.persona.Trim()}
    if($saved.revision-is [string]){$result.revision=$saved.revision}
  }catch{}
  return $result
}
function Save-WidgetGenerationSettings([string]$DataDir,$Value) {
  $saved=@{version=1;revision=[Guid]::NewGuid().ToString('N');enabled=[bool]$Value.enabled}
  foreach($spec in @(@('threshold',1,1000),@('batchSize',1,200),@('maxDaily',1,100),@('minIntervalMinutes',1,1440))){
    $number=0
    if(![int]::TryParse([string]$Value[$spec[0]],[ref]$number) -or $number-lt $spec[1] -or $number-gt $spec[2]){throw ($spec[0]+' 须为 '+$spec[1]+'–'+$spec[2]+' 之间的整数。')}
    $saved[$spec[0]]=$number
  }
  if($Value.model-isnot [string] -or $Value.model-notmatch '^[A-Za-z0-9._:/-]{0,160}$'){throw '请填写有效模型名，或留空沿用 Codex CLI 模型配置。'}
  if($Value.persona-isnot [string] -or !$Value.persona.Trim() -or $Value.persona.Length-gt 6000){throw '人设与规则须为 1–6000 个字符。'}
  $saved.model=$Value.model;$saved.persona=$Value.persona.Trim()
  Write-WidgetQuoteJson (Join-Path $DataDir 'quote-generation.json') $saved
}

function Save-WidgetQuotes([string]$DataDir,$Quotes) {
  $rows=@(ConvertTo-WidgetQuoteRows $Quotes)
  $library=Read-WidgetQuoteLibrary $DataDir
  if($null-ne $library){$library.base=$rows;Save-WidgetQuoteLibrary $DataDir $library;return Get-WidgetQuoteSettings $DataDir}
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
  $library=Read-WidgetQuoteLibrary $DataDir
  if($null-ne $library){
    $library.base=@(Read-WidgetQuoteFile $script:widgetQuotesBuiltInPath)
    $baseKeys=@{};foreach($row in $library.base){$baseKeys[(Get-WidgetQuoteKey $row.text)]=$true}
    $library.deleted=@($library.deleted|Where-Object{!$baseKeys.ContainsKey((Get-WidgetQuoteKey $_.text))})
    Save-WidgetQuoteLibrary $DataDir $library
    return Get-WidgetQuoteSettings $DataDir
  }
  $file=Join-Path $DataDir 'quotes.json'
  if([IO.File]::Exists($file)){
    [IO.File]::Copy($file,($file+'.bak'),$true)
    [IO.File]::Delete($file)
  }
  Get-WidgetQuoteSettings $DataDir
}

# The UI alone writes this overlay; the worker alone appends generated stock.
# A single atomic overlay commits moves, deletes and restores together.
function Read-WidgetQuoteLibrary([string]$DataDir) {
  try{
    $saved=[IO.File]::ReadAllText((Join-Path $DataDir 'quote-library.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json
    if($saved.base-isnot [Array]){return $null}
    $deleted=@(foreach($row in $saved.deleted){if($row.text-is [string]){[pscustomobject]@{text=$row.text;weight=$row.weight;preferred=[bool]$row.preferred;source=[string]$row.source}}})
    return @{version=1;base=@(ConvertTo-WidgetQuoteRows $saved.base);deleted=$deleted}
  }catch{return $null}
}
function Get-WidgetQuoteLibrary([string]$DataDir) {
  $saved=Read-WidgetQuoteLibrary $DataDir
  if($null-ne $saved){return $saved}
  return @{version=1;base=@((Get-WidgetQuoteSettings $DataDir).quotes);deleted=@()}
}
function Save-WidgetQuoteLibrary([string]$DataDir,$Library) {
  $rows=@(ConvertTo-WidgetQuoteRows $Library.base);$keys=@{}
  foreach($row in $rows){$keys[(Get-WidgetQuoteKey $row.text)]=$true}
  $deleted=@($Library.deleted|Where-Object{!$keys.ContainsKey((Get-WidgetQuoteKey $_.text))})
  Write-WidgetQuoteJson (Join-Path $DataDir 'quote-library.json') @{version=1;base=$rows;deleted=$deleted}
}
function Get-WidgetGeneratedQuotes([string]$DataDir) {
  $library=Get-WidgetQuoteLibrary $DataDir;$excluded=@{}
  foreach($row in @($library.base)+@($library.deleted)){$excluded[(Get-WidgetQuoteKey $row.text)]=$true}
  try{foreach($row in @(Read-WidgetQuoteFile (Join-Path $DataDir 'generated-quotes.json'))){if(!$excluded.ContainsKey((Get-WidgetQuoteKey $row.text))){$row}}}catch{}
}
function Move-WidgetGeneratedQuote([string]$DataDir,[string]$Text) {
  $row=@(Get-WidgetGeneratedQuotes $DataDir|Where-Object{(Get-WidgetQuoteKey $_.text)-eq (Get-WidgetQuoteKey $Text)})
  if(!$row.Count){return}
  $library=Get-WidgetQuoteLibrary $DataDir;$library.base+=@($row[0]);Save-WidgetQuoteLibrary $DataDir $library
}
function Remove-WidgetLibraryQuote([string]$DataDir,[string]$Text,[string]$Source) {
  $library=Get-WidgetQuoteLibrary $DataDir;$key=Get-WidgetQuoteKey $Text
  $rows=if($Source-eq 'base'){@($library.base)}else{@(Get-WidgetGeneratedQuotes $DataDir)}
  $row=@($rows|Where-Object{(Get-WidgetQuoteKey $_.text)-eq $key})
  if(!$row.Count){return}
  $library.base=@($library.base|Where-Object{(Get-WidgetQuoteKey $_.text)-ne $key})
  $library.deleted=@($library.deleted|Where-Object{(Get-WidgetQuoteKey $_.text)-ne $key})+@([pscustomobject]@{text=$row[0].text;weight=$row[0].weight;preferred=[bool]$row[0].preferred;source=$Source})
  Save-WidgetQuoteLibrary $DataDir $library
}
function Restore-WidgetLibraryQuote([string]$DataDir,[string]$Text) {
  $library=Get-WidgetQuoteLibrary $DataDir;$key=Get-WidgetQuoteKey $Text
  $row=@($library.deleted|Where-Object{(Get-WidgetQuoteKey $_.text)-eq $key})
  if(!$row.Count){return}
  $library.deleted=@($library.deleted|Where-Object{(Get-WidgetQuoteKey $_.text)-ne $key})
  if($row[0].source-eq 'base'){$library.base+=@($row[0])}
  Save-WidgetQuoteLibrary $DataDir $library
}
