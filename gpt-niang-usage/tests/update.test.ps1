$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
# Dot source into this test scope; no task/shortcut/CLI installation is performed.
. (Join-Path $source 'runtime\update-helper.ps1') -FunctionsOnly
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $source 'runtime\update-ui.ps1'),[Text.Encoding]::UTF8)))
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-updater-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot
$script:agent=Join-Path $testRoot 'agent'
function Get-WidgetUpdateAgentDir {return $script:agent}
function Get-FileHash {throw 'Get-FileHash module is unavailable in this fixture.'}
$script:jsonWriter=(Get-Command Write-WidgetSupervisorJson).ScriptBlock
function Write-WidgetSupervisorJson([string]$File,$Value) {
  if($script:failureMode-eq 'status' -and $Value.phase-eq 'updated'){throw 'Simulated committed status write failure.'}
  & $script:jsonWriter $File $Value
}
function Get-ScheduledTask {return @()}
$startup=Join-Path ([Environment]::GetFolderPath('Startup')) 'GPT Niang Usage.lnk'
function Test-Path {
  [CmdletBinding(DefaultParameterSetName='Path')]
  param([Parameter(Position=0,ParameterSetName='Path')][string[]]$Path,[Parameter(ParameterSetName='LiteralPath')][string[]]$LiteralPath,[Microsoft.PowerShell.Commands.TestPathType]$PathType)
  if($LiteralPath.Count-eq 1 -and $LiteralPath[0]-eq $script:startup){return $false}
  Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
}
function Stop-WidgetSupervisorTask {$script:stops++}
function Stop-WidgetGui {$script:stops++}
function Wait-WidgetUpdateIdle {}
function Assert-WidgetCandidatePackage {}
function Assert-WidgetPluginRegistration([string]$Codex,[string]$Version){
  $catalog=Read-WidgetUpdateJson (Join-Path $testRoot 'catalog.json')
  if($catalog.version-ne $Version -or !$catalog.installed -or !$catalog.enabled){throw 'Isolated plugin registration mismatch.'}
}
function Get-CimInstance {
  return [pscustomobject]@{Name='powershell.exe';CommandLine=('powershell.exe -File "'+(Join-Path $script:agent 'update-agent.ps1')+'"')}
}
$script:healthValidator=(Get-Command Wait-WidgetUpdatedHealth).ScriptBlock
function Wait-WidgetUpdatedHealth($Journal) {
  if($script:failureMode-eq 'health'){throw 'Simulated new supervisor health failure.'}
  & $script:healthValidator $Journal
}
function Invoke-WidgetUpdateInstaller($Journal,[string]$Token) {
  $script:installerCalls++
  $manifest=Read-WidgetUpdateJson (Join-Path $Journal.appDir '.codex-plugin\plugin.json')
  if($script:failureMode-eq 'install' -and $manifest.version-eq '1.3.3'){throw 'Simulated plugin registration failure.'}
  $config=Read-WidgetUpdateJson (Join-Path $Journal.appDir 'installation.json');$config.version=$manifest.version
  Write-WidgetSupervisorJson (Join-Path $Journal.appDir 'installation.json') $config
  Write-WidgetSupervisorJson (Join-Path $testRoot 'catalog.json') @{version=$manifest.version;installed=$true;enabled=$true}
  Write-WidgetSupervisorJson (Join-Path $Journal.dataDir 'supervisor-status.json') @{pid=$PID;at=[DateTime]::UtcNow.ToString('o')}
}
$checks=0
function Assert($Condition,[string]$Label){if(!$Condition){throw ('Assertion failed: '+$Label)};$script:checks++;Write-Output ('PASS '+$Label)}
function Assert-Throws([scriptblock]$Action,[string]$Label){try{& $Action|Out-Null}catch{$script:checks++;Write-Output ('PASS '+$Label);return};throw ('Expected failure: '+$Label)}
function New-Fixture([string]$Name,[switch]$Embedded) {
  $case=Join-Path $testRoot $Name;$root=Join-Path $case 'install';$app=Join-Path $root 'gpt-niang-usage'
  $null=New-Item -ItemType Directory -Path $root -Force
  Copy-Item -LiteralPath $source -Destination $app -Recurse
  foreach($name in @('package.json','.codex-plugin\plugin.json')){
    $file=Join-Path $app $name;$value=Read-WidgetUpdateJson $file;$value.version='1.3.2';Write-WidgetSupervisorJson $file $value
  }
  $metadata=Join-Path $root '.agents\plugins';$null=New-Item -ItemType Directory -Path $metadata -Force
  Copy-Item -LiteralPath (Join-Path (Split-Path $source -Parent) '.agents\plugins\marketplace.json') -Destination $metadata
  $data=if($Embedded){Join-Path $root 'state'}else{Join-Path $case 'state'}
  $null=New-Item -ItemType Directory -Path $data -Force
  Write-WidgetSupervisorJson (Join-Path $app 'installation.json') @{appDir=$app;dataDir=$data;version='1.3.2';codexPath='isolated-codex';updateAgent=$script:agent}
  Write-WidgetSupervisorJson (Join-Path $data 'settings.json') @{scale=1.4;soundOn=$false;desktopLeft=123;desktopTop=456}
  Write-WidgetSupervisorJson (Join-Path $data 'update-preferences.json') @{automatic=$false}
  [IO.File]::WriteAllText((Join-Path $data 'quotes.txt'),'custom quote')
  $token=[Guid]::NewGuid().ToString('D');$job=Join-Path $data ('updates\'+$token)
  $candidate=Join-Path $job 'package\bundle';$null=New-Item -ItemType Directory -Path $candidate -Force
  Copy-Item -LiteralPath $source -Destination (Join-Path $candidate 'gpt-niang-usage') -Recurse
  $candidateMetadata=Join-Path $candidate '.agents\plugins';$null=New-Item -ItemType Directory -Path $candidateMetadata -Force
  Copy-Item -LiteralPath (Join-Path (Split-Path $source -Parent) '.agents\plugins\marketplace.json') -Destination $candidateMetadata
  foreach($name in @('package.json','.codex-plugin\plugin.json')){
    $file=Join-Path $candidate ('gpt-niang-usage\'+$name);$value=Read-WidgetUpdateJson $file;$value.version='1.3.3';Write-WidgetSupervisorJson $file $value
  }
  $archive=Join-Path $job 'release.zip';[IO.File]::WriteAllText($archive,'already validated ZIP fixture')
  Write-WidgetSupervisorJson (Join-Path $script:agent 'binding.json') @{sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;appDir=$app;dataDir=$data}
  $script:stops=0;$script:installerCalls=0;$script:failureMode=''
  return [pscustomobject]@{schema=1;token=$token;phase='prepared';root=$root;appDir=$app;dataDir=$data;candidate=$candidate;archive=$archive;hash=(Get-WidgetFileHash $archive);version='1.3.3';oldVersion='1.3.2';mode='manual'}
}
try {
  $hashFile=Join-Path $testRoot 'sha-test.txt';[IO.File]::WriteAllText($hashFile,'abc')
  Assert ((Get-WidgetFileHash $hashFile)-eq 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD') 'SHA256 works without Get-FileHash module autoload'
  $journal=New-Fixture 'upgrade'
  [IO.File]::WriteAllText((Join-Path $journal.root 'screenshot.png'),'personal screenshot')
  $personal=Join-Path $journal.root 'my downloads';$null=New-Item -ItemType Directory -Path $personal
  [IO.File]::WriteAllText((Join-Path $personal 'old-package.zip'),'manually downloaded archive')
  $installedDocs=Join-Path $journal.root 'docs';$null=New-Item -ItemType Directory -Path $installedDocs
  [IO.File]::WriteAllText((Join-Path $installedDocs 'development-alignment.md'),'old release docs')
  $candidateDocs=Join-Path $journal.candidate 'docs';$null=New-Item -ItemType Directory -Path $candidateDocs
  [IO.File]::WriteAllText((Join-Path $candidateDocs 'development-alignment.md'),'new release docs')
  $stopLauncher=([string][char]0x505c)+([string][char]0x7528)+'GPT'+([string][char]0x5A18)+'.cmd'
  [IO.File]::WriteAllText((Join-Path $journal.root $stopLauncher),'old launcher')
  [IO.File]::WriteAllText((Join-Path $journal.candidate $stopLauncher),'new launcher')
  Invoke-WidgetUpdateTransaction $journal $script:agent $journal.token
  Assert ($journal.phase-eq 'committed') 'upgrade commits after registration and real heartbeat validation'
  Assert ((Read-WidgetUpdateJson (Join-Path $journal.appDir 'installation.json')).version-eq '1.3.3') 'new plugin version registered'
  Assert (!(Test-Path -LiteralPath $journal.backup) -and !$journal.cleanupPending) 'confirmed upgrade removes the complete previous program backup'
  Assert (!(Test-Path -LiteralPath (Split-Path $journal.archive -Parent))) 'confirmed upgrade removes the archive and extracted cache'
  Assert ((Read-WidgetUpdateJson (Join-Path $journal.dataDir 'settings.json')).scale-eq 1.4) 'position and appearance preferences preserved'
  Assert (!(Read-WidgetUpdateJson (Join-Path $journal.dataDir 'update-preferences.json')).automatic) 'disabled automatic-update preference preserved'
  Assert ([IO.File]::ReadAllText((Join-Path $journal.root 'screenshot.png'))-eq 'personal screenshot') 'unrelated screenshots remain at their original active path'
  Assert ([IO.File]::ReadAllText((Join-Path $journal.root 'my downloads\old-package.zip'))-eq 'manually downloaded archive') 'unmanaged download folders survive old-version cleanup'
  Assert ([IO.File]::ReadAllText((Join-Path $journal.root 'docs\development-alignment.md'))-eq 'new release docs') 'release-managed docs replace the prior package docs without colliding with personal files'
  Assert ([IO.File]::ReadAllText((Join-Path $journal.root $stopLauncher))-eq 'new launcher') 'release-managed Chinese launcher filenames remain valid in Windows PowerShell 5.1'

  $journal=New-Fixture 'personal-collision'
  [IO.File]::WriteAllText((Join-Path $journal.root 'user.txt'),'personal file')
  [IO.File]::WriteAllText((Join-Path $journal.candidate 'user.txt'),'unexpected package file')
  Assert-Throws {Invoke-WidgetUpdateTransaction $journal $script:agent $journal.token} 'personal file collision blocks replacement'
  Assert ($script:stops-eq 0 -and [IO.File]::ReadAllText((Join-Path $journal.root 'user.txt'))-eq 'personal file') 'personal collision is rejected before shutdown and preserves the original'

  $journal=New-Fixture 'committed-status';$script:failureMode='status'
  Invoke-WidgetUpdateTransaction $journal $script:agent $journal.token
  Assert ($journal.phase-eq 'committed' -and $script:installerCalls-eq 1) 'status write failure after commit does not roll back a healthy upgrade'
  Assert (!(Test-Path -LiteralPath $journal.backup)) 'committed status failure does not skip automatic cleanup'

  $journal=New-Fixture 'embedded-data' -Embedded
  [IO.File]::WriteAllText((Join-Path $journal.root 'user-note.txt'),'personal note alongside embedded state')
  Invoke-WidgetUpdateTransaction $journal $script:agent $journal.token
  Assert ($journal.phase-eq 'committed' -and [IO.File]::ReadAllText((Join-Path $journal.dataDir 'quotes.txt'))-eq 'custom quote') 'embedded data copied and verified before replacement'
  Assert ([IO.File]::ReadAllText((Join-Path $journal.root 'user-note.txt'))-eq 'personal note alongside embedded state') 'embedded state and unrelated personal files are preserved together'

  $journal=New-Fixture 'data-collision' -Embedded
  $null=New-Item -ItemType Directory -Path (Join-Path $journal.candidate 'state')
  Assert-Throws {Invoke-WidgetUpdateTransaction $journal $script:agent $journal.token} 'candidate cannot overwrite an embedded data directory'
  Assert ($script:stops-eq 0 -and $script:installerCalls-eq 0) 'data path collision is rejected before stopping the program'

  $journal=New-Fixture 'bad-hash';$journal.hash='0'*64
  Assert-Throws {Invoke-WidgetUpdateTransaction $journal $script:agent $journal.token} 'changed archive rejected'
  Assert ($script:stops-eq 0 -and $script:installerCalls-eq 0) 'failed validation never stops or runs installer'

  $journal=New-Fixture 'failed-install';$script:failureMode='install'
  Assert-Throws {Invoke-WidgetUpdateTransaction $journal $script:agent $journal.token} 'installation failure triggers rollback'
  Assert ($journal.phase-eq 'rolled-back' -and (Read-WidgetUpdateJson (Join-Path $journal.appDir 'installation.json')).version-eq '1.3.2') 'failed new registration restores and registers old plugin'
  Assert (!(Test-Path -LiteralPath $journal.failedRoot) -and !(Test-Path -LiteralPath (Split-Path $journal.archive -Parent))) 'successful rollback cleans failed replacement and download cache'

  $journal=New-Fixture 'failed-health';$script:failureMode='health'
  Assert-Throws {Invoke-WidgetUpdateTransaction $journal $script:agent $journal.token} 'backup is retained until the new supervisor passes health validation'
  Assert ($journal.phase-eq 'rolled-back' -and (Read-WidgetUpdateJson (Join-Path $journal.appDir 'installation.json')).version-eq '1.3.2') 'failed health validation restores the original version before cleanup'

  $journal=New-Fixture 'interrupted-rename'
  Assert-WidgetUpdateTransaction $journal $script:agent
  Set-WidgetUpdatePhase $journal 'moving-new' $script:agent
  [IO.Directory]::Move($journal.root,$journal.backup)
  Invoke-WidgetUpdateTransaction $journal $script:agent $journal.token -Recover
  Assert ($journal.phase-eq 'rolled-back' -and (Test-Path -LiteralPath $journal.appDir)) 'restart recovery restores missing program directory'

  $journal=New-Fixture 'interrupted-registration'
  Assert-WidgetUpdateTransaction $journal $script:agent
  Copy-WidgetVerifiedTree $journal.candidate $journal.nextRoot
  Copy-Item -LiteralPath (Join-Path $journal.appDir 'installation.json') -Destination (Join-Path $journal.nextRoot 'gpt-niang-usage\installation.json')
  [IO.Directory]::Move($journal.root,$journal.backup);[IO.Directory]::Move($journal.nextRoot,$journal.root)
  Set-WidgetUpdatePhase $journal 'registering' $script:agent
  Invoke-WidgetUpdateTransaction $journal $script:agent $journal.token -Recover
  Assert ((Read-WidgetUpdateJson (Join-Path $journal.appDir '.codex-plugin\plugin.json')).version-eq '1.3.2') 'restart before commit restores original files'

  $journal=New-Fixture 'locked-files'
  $locked=Join-Path $journal.root 'locked.txt';[IO.File]::WriteAllText($locked,'locked')
  $stream=[IO.File]::Open($locked,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
  try{Assert-Throws {Invoke-WidgetUpdateTransaction $journal $script:agent $journal.token} 'occupied Windows files reject replacement'}finally{$stream.Dispose()}
  Assert ($journal.phase-eq 'rolled-back' -and (Test-Path -LiteralPath $journal.appDir)) 'occupied old program is retained and restarted'

  $journal=New-Fixture 'broken-recovery';$journal.phase='moving-new'
  Remove-Item -LiteralPath (Join-Path $journal.appDir 'installation.json')
  Assert-Throws {Invoke-WidgetUpdateTransaction $journal $script:agent $journal.token -Recover} 'missing old configuration stops recovery'
  Assert ($journal.phase-eq 'recovery-failed' -and (Test-Path -LiteralPath (Join-Path $script:agent 'update-diagnostic.txt'))) 'failed recovery keeps diagnosis and blocks automatic retry'
  Assert (Test-Path -LiteralPath (Split-Path $journal.archive -Parent)) 'failed recovery preserves the downloaded recovery files'
  Assert-Throws {Restore-WidgetUpdate $journal $script:agent $journal.token} 'failed recovery cannot be automatically repeated'

  $journal=New-Fixture 'cleanup-locked'
  $journal.phase='committed';Assert-WidgetUpdateTransaction $journal $script:agent
  Copy-WidgetVerifiedTree $journal.root $journal.backup
  $held=Join-Path $journal.backup 'held.txt';[IO.File]::WriteAllText($held,'locked backup')
  $stream=[IO.File]::Open($held,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
  try{
    Assert (!(Complete-WidgetUpdateCleanup $journal $script:agent) -and $journal.cleanupPending) 'occupied backup keeps a pending cleanup record'
    Assert ($journal.phase-eq 'committed' -and (Test-Path -LiteralPath $journal.appDir)) 'cleanup failure never rolls back a committed program'
  }finally{$stream.Dispose()}
  Assert (Complete-WidgetUpdateCleanup $journal $script:agent) 'pending cleanup can be retried after the file is released'
  Assert (!(Test-Path -LiteralPath $journal.backup) -and !$journal.cleanupPending) 'cleanup retry removes the backup and clears its pending record'

  $journal=New-Fixture 'cache-ownership'
  $journal.phase='rolled-back'
  $ownedToken=[Guid]::NewGuid().ToString('D');$owned=Join-Path $journal.dataDir ('updates\'+$ownedToken)
  Write-WidgetSupervisorJson (Join-Path $owned 'update-job.json') @{schema=1;token=$ownedToken;appDir=$journal.appDir;dataDir=$journal.dataDir}
  [IO.File]::WriteAllText((Join-Path $owned 'release.zip'),'orphaned download')
  $foreignToken=[Guid]::NewGuid().ToString('D');$foreign=Join-Path $journal.dataDir ('updates\'+$foreignToken)
  Write-WidgetSupervisorJson (Join-Path $foreign 'update-job.json') @{schema=1;token=$foreignToken;appDir='C:\another-app';dataDir=$journal.dataDir}
  Assert (Complete-WidgetUpdateCleanup $journal $script:agent) 'terminal cleanup also reclaims owned interrupted download caches'
  Assert (!(Test-Path -LiteralPath $owned) -and (Test-Path -LiteralPath $foreign)) 'foreign cache directories are preserved'
  Assert ([IO.File]::ReadAllText((Join-Path $journal.dataDir 'quotes.txt'))-eq 'custom quote') 'cache cleanup preserves custom quote data'

  $journal=New-Fixture 'cleanup-links';$journal.phase='committed';Assert-WidgetUpdateTransaction $journal $script:agent
  $outside=Join-Path $testRoot 'unrelated';$null=New-Item -ItemType Directory -Path $outside
  [IO.File]::WriteAllText((Join-Path $outside 'keep.txt'),'unrelated')
  $null=New-Item -ItemType Junction -Path $journal.backup -Target $outside
  try{
    Assert (!(Complete-WidgetUpdateCleanup $journal $script:agent)) 'linked backup cleanup is rejected'
    Assert ([IO.File]::ReadAllText((Join-Path $outside 'keep.txt'))-eq 'unrelated') 'cleanup never traverses a link into unrelated files'
  }finally{[IO.Directory]::Delete($journal.backup)}

  $lock=Enter-WidgetUpdateLock -AgentDir $script:agent
  try{Assert-Throws {Enter-WidgetUpdateLock -AgentDir $script:agent} 'installer/update/uninstall lock is exclusive'}finally{Exit-WidgetUpdateLock $lock}
  $lock=Enter-WidgetUpdateLock -AgentDir $script:agent
  try{
    $helper=Enter-WidgetUpdateLock -AgentDir $script:agent -Token $lock.Token
    $nested=Enter-WidgetUpdateLock -AgentDir $script:agent -Token $lock.Token
    Exit-WidgetUpdateLock $nested
    Assert ((Read-WidgetUpdateJson (Join-Path $lock.Directory 'owner.json')).helperPid-eq $PID) 'nested installer does not release its parent helper claim'
    Exit-WidgetUpdateLock $helper
    Assert (!(Read-WidgetUpdateJson (Join-Path $lock.Directory 'owner.json')).helperPid) 'cleanup helper returns its claim before the install helper starts'
  }finally{Exit-WidgetUpdateLock $lock}
  $script:dataDir=Join-Path $testRoot 'ui-preferences';$null=New-Item -ItemType Directory -Path $script:dataDir
  $script:settingsMenuUi=@{}
  Initialize-WidgetUpdater;Assert $script:autoUpdate 'WPF automatic-update default is on'
  Set-WidgetAutomaticUpdate $false;Initialize-WidgetUpdater;Assert (!$script:autoUpdate) 'WPF toggle survives initialization'
  $script:context=[pscustomobject]@{IsOpen=$false};$script:disposedUpdater=$false
  $script:updateProcess=[pscustomobject]@{HasExited=$true;ExitCode=12}
  $script:updateProcess|Add-Member ScriptMethod Dispose {$script:disposedUpdater=$true}
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Tick-WidgetUpdater $now
  $failed=Read-WidgetUpdateJson (Join-Path $script:dataDir 'update-status.json')
  Assert ($failed.phase-eq 'failed' -and $failed.nextCheckAt-ge $now+86400000 -and $script:disposedUpdater -and !$script:updateProcess) 'unexpected updater exit reports failure, releases its handle and delays background retries'
  $script:startedModes=New-Object 'Collections.Generic.List[string]'
  function Start-WidgetUpdate([string]$Mode){$script:startedModes.Add($Mode)}
  $script:updateStartedAt=$now-30000;$script:updateLastTick=0
  Tick-WidgetUpdater $now
  Assert ($script:startedModes.Count-eq 1 -and $script:startedModes[0]-eq 'cleanup') 'startup retries cleanup even when automatic updates are disabled'
  Write-Output ("All $checks isolated Windows updater assertions passed.")
} finally {
  Assert-WidgetUpdateChildPath $testRoot ([IO.Path]::GetTempPath())
  Remove-Item -LiteralPath $testRoot -Recurse -Force
}
