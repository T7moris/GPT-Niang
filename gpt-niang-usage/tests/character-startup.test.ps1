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
  foreach($follow in @($true,$false)){
    $mode=if($follow){'follow host'}else{'desktop'}
    $volume=if($follow){0.35}else{0.9}
    $cases+=@(
      @{name=('saved built-in / '+$mode);id='test-alternative';follow=$follow;volume=$volume;expected='test-alternative'},
      @{name=('missing ID / '+$mode);id='missing-id';follow=$follow;volume=$volume;expected='gpt-dragon'},
      @{name=('corrupt selected PNG / '+$mode);id=$customId;follow=$follow;volume=$volume;expected='gpt-dragon'}
    )
  }
  foreach($case in $cases){
    if($null-ne $case.id){[IO.File]::WriteAllText($settings,(@{characterId=$case.id;scale=0.6;followHost=$case.follow;soundVolume=$case.volume}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
    elseif([IO.File]::Exists($settings)){[IO.File]::Delete($settings)}
    $settingsBefore=if([IO.File]::Exists($settings)){[IO.File]::ReadAllText($settings)}else{$null}
    $output=& $powerShell -NoProfile -STA -ExecutionPolicy Bypass -File $wrapper -AppDir $fixtureApp
    if($LASTEXITCODE-ne 0){throw ($case.name+' startup failed: '+($output|Out-String))}
    $result=($output|Out-String)|ConvertFrom-Json
    if(!$result.ok -or !$result.imageLoaded -or $result.characterId-ne $case.expected){throw ($case.name+' startup returned an unexpected character: '+($output|Out-String))}
    if($null-eq $result.soundVolume -or [Math]::Abs([double]$result.soundVolume-[double]$case.volume)-gt 0.000000000001){throw ($case.name+' startup did not restore fractional sound volume '+$case.volume+': '+($output|Out-String))}
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
