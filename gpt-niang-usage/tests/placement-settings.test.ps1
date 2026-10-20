param([string]$AppUnderTest=(Split-Path $PSScriptRoot -Parent),[string]$ResultPath)
$ErrorActionPreference='Stop'
. (Join-Path $AppUnderTest 'runtime\update-common.ps1')
function Get-FileHash {throw 'Get-FileHash module is unavailable in this fixture.'}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('gpt-placement-settings-'+[Guid]::NewGuid().ToString('N'))
$app=Join-Path $testRoot 'app';$data=Join-Path $testRoot 'state'
$native=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$utf8=[Text.UTF8Encoding]::new($false)
$cases=@(
  @{name='negative-bottom';value=-12;expected=-12},
  @{name='negative-fraction';value=-0.375;expected=-0.375},
  @{name='large-negative';value=-150;expected=-150},
  @{name='positive';value=24;expected=24},
  @{name='zero';value=0;expected=0},
  @{name='missing';omit=$true;expected=0},
  @{name='NaN';value='NaN';expected=0},
  @{name='infinity';value='Infinity';expected=0},
  @{name='legacy-migration';value=-12;version=1;expected=0}
)
$results=@()
try{
  $null=New-Item -ItemType Directory -Path $testRoot
  Copy-Item -LiteralPath $AppUnderTest -Destination $app -Recurse
  $null=New-Item -ItemType Directory -Path $data
  $config=@{appDir=$app;dataDir=$data;codexPath='unused-check-only';version='1.3.4'}
  [IO.File]::WriteAllText((Join-Path $app 'installation.json'),($config|ConvertTo-Json),$utf8)
  foreach($case in $cases){
    $settings=@{layoutVersion=2;left=-20;anchor='free';side='right';scale=0.6;bubbleScale=1.0}
    if(!$case.omit){$settings.bottom=$case.value}
    if($case.version){$settings.layoutVersion=$case.version}
    $settingsFile=Join-Path $data 'settings.json'
    [IO.File]::WriteAllText($settingsFile,($settings|ConvertTo-Json),$utf8)
    $before=Get-WidgetFileHash $settingsFile
    $output=& $native -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $app 'runtime\start-widget.ps1') -WidgetPath (Join-Path $app 'widget.ps1') -CheckOnly
    if($LASTEXITCODE-ne 0){throw ('Full startup check failed: '+$case.name)}
    $state=($output -join [Environment]::NewLine)|ConvertFrom-Json
    if(!$state.ok -or [double]$state.placement.bottom-ne $case.expected){throw ($case.name+': expected '+$case.expected+', got '+$state.placement.bottom)}
    if([double]$state.sizing.character-ne 0.6 -or [double]$state.sizing.bubble-ne 1.0){throw ('Sizing was changed by settings read: '+$case.name)}
    if((Get-WidgetFileHash $settingsFile)-ne $before){throw ('Check-only rewrote preferences: '+$case.name)}
    $results+=@{name=$case.name;expected=$case.expected;actual=$state.placement.bottom;settingsUnchanged=$true}
  }
  if($ResultPath){[IO.File]::WriteAllText($ResultPath,(@{passed=$true;cases=$results;fullNativeStartup=$true;uiShown=$false;liveSettingsReadOrWritten=$false}|ConvertTo-Json -Depth 5),$utf8)}
  Write-Output ('PASS: '+$results.Count+' full startup settings cases; negative/fractional/positive/invalid/legacy values, independent sizing and read-only preferences')
}finally{
  $resolved=[IO.Path]::GetFullPath($testRoot)
  $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\gpt-placement-settings-'
  if(!$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe temporary cleanup target'}
  if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
