param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
$sourceApp=Split-Path $TestRoot -Parent
$fixtureRoot=Join-Path $TestRoot ('character-startup-fixture-'+[Guid]::NewGuid().ToString('N'))
$fixtureApp=Join-Path $fixtureRoot 'app';$fixtureData=Join-Path $fixtureRoot 'data'
try{
  $null=[IO.Directory]::CreateDirectory($fixtureApp);$null=[IO.Directory]::CreateDirectory($fixtureData)
  foreach($directory in @('assets','runtime')){Copy-Item -LiteralPath (Join-Path $sourceApp $directory) -Destination $fixtureApp -Recurse}
  foreach($file in @('widget.ps1','widget.xaml')){Copy-Item -LiteralPath (Join-Path $sourceApp $file) -Destination $fixtureApp}
  Copy-Item -LiteralPath (Join-Path $fixtureApp 'assets\gpt-dragon-niang-bust.png') -Destination (Join-Path $fixtureApp 'assets\test-alternative.png')
  [IO.File]::WriteAllText((Join-Path $fixtureApp 'assets\characters.json'),(@{version=1;characters=@(@{id='test-alternative';name='Test alternative';file='test-alternative.png'})}|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
  $config=@{dataDir=$fixtureData;appDir=$fixtureApp}|ConvertTo-Json
  [IO.File]::WriteAllText((Join-Path $fixtureApp 'installation.json'),$config,[Text.UTF8Encoding]::new($false))
  $wrapper=Join-Path $fixtureRoot 'check-startup.ps1'
  # The real start-widget.ps1 entry point reads UTF8 explicitly; use the same contract.
  [IO.File]::WriteAllText($wrapper,@'
param([string]$AppDir)
$ErrorActionPreference='Stop'
$source=[IO.File]::ReadAllText((Join-Path $AppDir 'widget.ps1'),[Text.Encoding]::UTF8)
& ([ScriptBlock]::Create($source)) -AppDir $AppDir -CheckOnly
'@,[Text.UTF8Encoding]::new($false))
  $powerShell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $customId='custom-'+('c'*32)
  $customDirectory=Join-Path $fixtureData 'characters';$null=[IO.Directory]::CreateDirectory($customDirectory)
  [IO.File]::WriteAllText((Join-Path $customDirectory ($customId+'.png')),'corrupt PNG')
  $catalog=@{version=1;characters=@(@{id=$customId;name='Broken startup fixture';file=$customId+'.png'})}|ConvertTo-Json -Depth 5
  [IO.File]::WriteAllText((Join-Path $fixtureData 'characters.json'),$catalog,[Text.UTF8Encoding]::new($false))
  $settings=Join-Path $fixtureData 'settings.json'
  $cases=@(@{name='no settings';id=$null;follow=$true;volume=0.9;expected='gpt-dragon'})
  $cases+=@{name='negative flush offsets';id='test-alternative';follow=$true;volume=0.37;expected='test-alternative';flush=$true}
  foreach($follow in @($true,$false)){
    $mode=if($follow){'follow host'}else{'desktop'}
    $volume=if($follow){0.35}else{0.9}
    $cases+=@(
      @{name=('saved built-in / '+$mode);id='test-alternative';follow=$follow;volume=$volume;expected='test-alternative'},
      @{name=('missing ID / '+$mode);id='missing-id';follow=$follow;volume=$volume;expected='gpt-dragon'},
      @{name=('corrupt selected PNG / '+$mode);id=$customId;follow=$follow;volume=$volume;expected='gpt-dragon'}
    )
  }
  foreach($bubbleValue in @(1.0,2.5,0.2,'invalid')){
    $cases+=@{name=('independent bubble '+$bubbleValue);id='test-alternative';follow=$true;volume=0.37;expected='test-alternative';bubble=$bubbleValue}
  }
  foreach($autoCase in @(@{enabled=$true;seconds=60;expectedEnabled=$true;expectedSeconds=60},@{enabled=$false;seconds=900;expectedEnabled=$false;expectedSeconds=900},@{enabled='true';seconds=60.1;expectedEnabled=$false;expectedSeconds=300},@{enabled=$true;seconds='invalid';expectedEnabled=$true;expectedSeconds=300})){
    $cases+=@{name=('automatic quote startup '+$autoCase.enabled+' / '+$autoCase.seconds);id='test-alternative';follow=$true;volume=0.37;expected='test-alternative';auto=$autoCase}
  }
  foreach($completionValue in @($true,$false,'false')){
    $cases+=@{name=('reply reminder '+$completionValue);id='test-alternative';follow=$true;volume=0.37;expected='test-alternative';completion=$completionValue}
  }
  foreach($case in $cases){
    if($null-ne $case.id){[IO.File]::WriteAllText($settings,(@{characterId=$case.id;scale=0.6;followHost=$case.follow;soundVolume=$case.volume;layoutVersion=2;right=781.6;left=54.4;bottom=87.2}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
    elseif([IO.File]::Exists($settings)){[IO.File]::Delete($settings)}
    if($case.flush){
      $saved=Get-Content -LiteralPath $settings -Raw -Encoding UTF8|ConvertFrom-Json
      $saved.right=-14;$saved.left=-14;$saved.bottom=-14
      [IO.File]::WriteAllText($settings,($saved|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    }
    if($case.ContainsKey('bubble')){
      $saved=Get-Content -LiteralPath $settings -Raw -Encoding UTF8|ConvertFrom-Json
      $saved|Add-Member -NotePropertyName bubbleScale -NotePropertyValue $case.bubble
      [IO.File]::WriteAllText($settings,($saved|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    }
    if($case.ContainsKey('auto')){
      $saved=Get-Content -LiteralPath $settings -Raw -Encoding UTF8|ConvertFrom-Json
      $saved|Add-Member -NotePropertyName autoQuoteEnabled -NotePropertyValue $case.auto.enabled
      $saved|Add-Member -NotePropertyName autoQuoteIntervalSeconds -NotePropertyValue $case.auto.seconds
      [IO.File]::WriteAllText($settings,($saved|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    }
    if($case.ContainsKey('completion')){
      $saved=Get-Content -LiteralPath $settings -Raw -Encoding UTF8|ConvertFrom-Json
      $saved|Add-Member -NotePropertyName taskCompletionBubble -NotePropertyValue $case.completion
      [IO.File]::WriteAllText($settings,($saved|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    }
    $settingsBefore=if([IO.File]::Exists($settings)){[IO.File]::ReadAllText($settings)}else{$null}
    $output=& $powerShell -NoProfile -STA -ExecutionPolicy Bypass -File $wrapper -AppDir $fixtureApp
    if($LASTEXITCODE-ne 0){throw ($case.name+' startup failed: '+($output|Out-String))}
    $result=($output|Out-String)|ConvertFrom-Json
    if(!$result.ok -or !$result.imageLoaded -or $result.characterId-ne $case.expected){throw ($case.name+' startup returned an unexpected character: '+($output|Out-String))}
    if($null-eq $result.soundVolume -or [Math]::Abs([double]$result.soundVolume-[double]$case.volume)-gt 0.000000000001){throw ($case.name+' startup did not restore fractional sound volume '+$case.volume+': '+($output|Out-String))}
    if($null-ne $case.id){
      foreach($coordinate in @(@{name='right';value=781.6},@{name='left';value=54.4},@{name='bottom';value=87.2})){
        if($case.flush){$coordinate.value=-14}
        if([Math]::Abs([double]$result.placement.($coordinate.name)-$coordinate.value)-gt 0.0000001){throw ($case.name+' rounded a saved placement coordinate: '+$coordinate.name)}
      }
    }
    $expectedSize=if($null-eq $case.id){1.0}else{0.6}
    $expectedBubble=if($case.ContainsKey('bubble') -and $case.bubble-is [double] -and $case.bubble-ge 0.6 -and $case.bubble-le 2.5){$case.bubble}else{$expectedSize}
    if($result.sizing.character-ne $expectedSize -or $result.sizing.bubble-ne $expectedBubble){throw 'Legacy combined size was not preserved by migration'}
    $expectedAutoEnabled=if($case.ContainsKey('auto')){$case.auto.expectedEnabled}else{$false}
    $expectedAutoSeconds=if($case.ContainsKey('auto')){$case.auto.expectedSeconds}else{300}
    if($result.autoQuotes.enabled-ne $expectedAutoEnabled -or $result.autoQuotes.intervalSeconds-ne $expectedAutoSeconds){throw 'Startup did not restore validated automatic quote settings'}
    $completionExpected=$case.ContainsKey('completion') -and $case.completion-is [bool] -and $case.completion
    if($result.completion.enabled-ne $completionExpected -or $result.completion.monitorPid-ne 0){throw 'CheckOnly did not restore strict reminder preference without starting a process'}
    if($result.dataDir-ne $fixtureData){throw 'Startup escaped the isolated fixture data directory'}
    $settingsAfter=if([IO.File]::Exists($settings)){[IO.File]::ReadAllText($settings)}else{$null}
    if($settingsAfter-cne $settingsBefore){throw 'CheckOnly unexpectedly persisted startup fallback'}
    Write-Output ('PASS: complete isolated CheckOnly startup - '+$case.name+' -> '+$result.characterId+', sound volume '+$result.soundVolume)
  }
}finally{
  $resolved=[IO.Path]::GetFullPath($fixtureRoot)
  $allowed=[IO.Path]::GetFullPath($TestRoot).TrimEnd([char[]]@('\','/'))+[IO.Path]::DirectorySeparatorChar
  if(!$resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe startup fixture cleanup path'}
  if([IO.Directory]::Exists($resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
