$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
. (Join-Path $source 'runtime\supervisor-task.ps1')
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-install-test-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot
$checks=0
function Assert($condition,[string]$label){if(!$condition){throw ('Assertion failed: '+$label)};$script:checks++;Write-Output ('PASS '+$label)}
function Assert-Throws([scriptblock]$action,[string]$pattern,[string]$label){try{& $action|Out-Null}catch{Assert ($_.Exception.Message-like $pattern) $label;return};throw ('Expected rejection: '+$label)}
try{
  $programRoot=Join-Path $testRoot 'program'
  $null=New-Item -ItemType Directory -Path $programRoot
  $moved=Join-Path $programRoot 'moved [folder]'
  Copy-Item -LiteralPath $source -Destination $moved -Recurse
  $metadata=Join-Path $programRoot '.agents\plugins'
  $null=New-Item -ItemType Directory -Path $metadata -Force
  Copy-Item -LiteralPath (Join-Path (Split-Path $source -Parent) '.agents\plugins\marketplace.json') -Destination $metadata
  # Override only the copied test runtime; never claim the real user's stable launcher.
  $commonFile=Join-Path $moved 'runtime\update-common.ps1'
  $common=[IO.File]::ReadAllText($commonFile)
  $isolatedAgent=Join-Path $testRoot 'update-agent'
  $common=$common.Replace("Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'GPTNiangUsage\update-agent'",("'"+$isolatedAgent.Replace("'","''")+"'"))
  [IO.File]::WriteAllText($commonFile,$common,[Text.UTF8Encoding]::new($false))
  $old=Join-Path $testRoot 'original'
  $data=Join-Path $testRoot 'state'
  $null=New-Item -ItemType Directory -Path $data
  Assert ((Get-WidgetInstallationDataDir $moved @{appDir=$moved;dataDir=$data})-eq $data) 'in-place upgrade preserves data path'
  [IO.File]::WriteAllText((Join-Path $data 'supervisor-disabled.flag'),'disabled')
  Assert ((Get-WidgetInstallationDataDir $moved @{appDir=$old;dataDir=$data})-eq $data) 'legacy disabled installation can move'
  $missingData=Join-Path $testRoot 'deleted-state'
  Assert ((Get-WidgetInstallationDataDir $moved @{appDir=$old;dataDir=$missingData;disabledAt='2026-10-02T00:00:00Z'})-eq $missingData) 'explicit disable survives deletion of preferences'
  $null=New-Item -ItemType Directory -Path $old
  Assert-Throws {Get-WidgetInstallationDataDir $moved @{appDir=$old;dataDir=$data;disabledAt='2026-10-02T00:00:00Z'}} '*original installation folder still exists*' 'copy cannot claim existing installation'
  Remove-Item -LiteralPath $old
  Assert-Throws {Get-WidgetInstallationDataDir $moved @{appDir=$old;dataDir=$missingData}} '*without disabling*' 'active moved installation is rejected'
  $shortcut=@{TargetPath=(Join-Path $env:WINDIR 'System32\wscript.exe');Arguments=('"'+(Join-Path $moved 'launch.vbs')+'"')}
  Assert (Test-WidgetStartupShortcutIdentity $shortcut $moved) 'bracket path shortcut matches literally'
  $shortcut.Arguments+=' "foreign script"'
  Assert (!(Test-WidgetStartupShortcutIdentity $shortcut $moved)) 'extra shortcut arguments are rejected'
  $shortcut.Arguments='"'+(Join-Path $moved 'launch.vbs')+'"'
  $shortcut.TargetPath=Join-Path $testRoot 'foreign.exe'
  Assert (!(Test-WidgetStartupShortcutIdentity $shortcut $moved)) 'foreign shortcut executable is rejected'

  # Stubs prevent reading or changing actual per-user task and startup registrations.
  $global:widgetInstallerTestStartup=Join-Path ([Environment]::GetFolderPath('Startup')) 'GPT Niang Usage.lnk'
  function Test-Path {
    [CmdletBinding(DefaultParameterSetName='Path')]
    param(
      [Parameter(Position=0,ParameterSetName='Path')][string[]]$Path,
      [Parameter(ParameterSetName='LiteralPath')][string[]]$LiteralPath,
      [Microsoft.PowerShell.Commands.TestPathType]$PathType,
      [switch]$IsValid
    )
    if($LiteralPath.Count-eq 1 -and $LiteralPath[0]-eq $global:widgetInstallerTestStartup){return $false}
    Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
  }
  function Get-ScheduledTask {$global:widgetInstallerTestTasks}
  $global:widgetInstallerTestTasks=@()
  function Get-CimInstance {return $null}
  $configFile=Join-Path $moved 'installation.json'
  $previous=@{appDir=$old;dataDir=$data}
  Write-WidgetSupervisorJson $configFile $previous
  $initialConfigBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile))
  $result=(& (Join-Path $moved 'Install.ps1') -CheckOnly)|ConvertFrom-Json
  Assert ($result.ok -and $result.appDir-eq $moved) 'moved installation passes full installer CheckOnly'
  Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile))-eq $initialConfigBytes) 'CheckOnly preserves installation config'
  try {
    $insideAgent=Join-Path $programRoot 'update-agent'
    [IO.File]::WriteAllText($commonFile,$common.Replace($isolatedAgent,$insideAgent),[Text.UTF8Encoding]::new($false))
    Assert-Throws {& (Join-Path $moved 'Install.ps1') -CheckOnly} '*must be outside the program directory*' 'stable launcher cannot be included in the replaceable program tree'
  } finally {[IO.File]::WriteAllText($commonFile,$common,[Text.UTF8Encoding]::new($false))}
  $workerFile=Join-Path $moved 'runtime\worker-state.mjs'
  $workerBytes=[IO.File]::ReadAllBytes($workerFile)
  try{
    Remove-Item -LiteralPath $workerFile
    Assert-Throws {& (Join-Path $moved 'Install.ps1') -CheckOnly} '*Missing file: runtime\worker-state.mjs' 'missing worker dependencies are rejected before registration'
  }finally{[IO.File]::WriteAllBytes($workerFile,$workerBytes)}
  $audioFile=Join-Path $moved 'runtime\audio-import.mjs'
  $audioBytes=[IO.File]::ReadAllBytes($audioFile)
  try{
    Remove-Item -LiteralPath $audioFile
    Assert-Throws {& (Join-Path $moved 'Install.ps1') -CheckOnly} '*Missing file: runtime\audio-import.mjs' 'missing audio converter is rejected before registration'
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile))-eq $initialConfigBytes) 'missing audio converter preserves installation config'
  }finally{[IO.File]::WriteAllBytes($audioFile,$audioBytes)}
  $colorFile=Join-Path $moved 'runtime\color-theme.ps1'
  $colorBytes=[IO.File]::ReadAllBytes($colorFile)
  try{
    Remove-Item -LiteralPath $colorFile
    Assert-Throws {& (Join-Path $moved 'Install.ps1') -CheckOnly} '*Missing file: runtime\color-theme.ps1' 'missing color module is rejected before registration'
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile))-eq $initialConfigBytes) 'missing color module rejection preserves config'
  }finally{[IO.File]::WriteAllBytes($colorFile,$colorBytes)}
  $info=Get-WidgetSupervisorInfo $moved @{appDir=$moved;dataDir=$data}
  $global:widgetInstallerTestTasks=@([pscustomobject]@{TaskName=$info.TaskName;TaskPath=$info.TaskPath;Principal=@{UserId=$info.Sid;LogonType='Interactive';RunLevel='Limited'};Actions=@(@{Execute=$info.Execute;Arguments='"'+(Join-Path $old 'supervisor.vbs')+'"';WorkingDirectory=$old})})
  Assert-Throws {& (Join-Path $moved 'Install.ps1') -CheckOnly} '*task action path mismatch*' 'foreign task is rejected during CheckOnly'
  Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile))-eq $initialConfigBytes) 'foreign task rejection preserves config'

  # Reproduce a surviving stable task/shortcut after update-agent state was lost.
  # Keep every read and recreated agent inside the isolated fixture.
  . $commonFile
  $bindingFile=Join-Path $isolatedAgent 'binding.json'
  $installed=@{appDir=$moved;dataDir=$data;updateAgent=$isolatedAgent}
  Write-WidgetSupervisorJson $configFile $installed
  $installedBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile))
  $stableInfo=Get-WidgetSupervisorInfo $moved $installed
  $stableTask=[pscustomobject]@{TaskName=$stableInfo.TaskName;TaskPath=$stableInfo.TaskPath;State='Ready';Principal=@{UserId=$stableInfo.Sid;LogonType='Interactive';RunLevel='Limited'};Actions=@(@{Execute=$stableInfo.Execute;Arguments=$stableInfo.Arguments;WorkingDirectory=$stableInfo.WorkingDirectory})}
  $global:widgetInstallerTestTasks=@($stableTask)
  $wscript=Join-Path $env:WINDIR 'System32\wscript.exe'
  $logicalAgent=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'GPTNiangUsage\update-agent'
  foreach($oldAgent in @($isolatedAgent,$logicalAgent)){
    $oldStableTask=[pscustomobject]@{TaskName=$stableInfo.TaskName;TaskPath=$stableInfo.TaskPath;Principal=$stableTask.Principal;Actions=@(@{Execute=$wscript;Arguments=('"'+(Join-Path $oldAgent 'agent-supervisor.vbs')+'"');WorkingDirectory=$oldAgent})}
    $oldStableAccepted=$true
    try{Assert-WidgetSupervisorTaskIdentity $oldStableTask $stableInfo}catch{$oldStableAccepted=$false}
    Assert $oldStableAccepted 'previous stable wscript supervisor path remains accepted'
  }
  $stableShortcut=@{TargetPath=(Join-Path $env:WINDIR 'System32\wscript.exe');Arguments=('"'+(Join-Path $isolatedAgent 'agent-launch.vbs')+'"')}
  $result=(& (Join-Path $moved 'Install.ps1') -CheckOnly)|ConvertFrom-Json
  Assert ($result.ok) 'missing binding with a verified existing task passes installer preflight'
  Assert (!(Test-Path -LiteralPath $bindingFile)) 'CheckOnly does not recreate missing binding'
  Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile))-eq $installedBytes) 'binding recovery preflight preserves installation config'
  Assert (Test-WidgetStartupShortcutIdentity $stableShortcut $moved) 'existing stable shortcut accepts verified missing binding'
  Stop-WidgetSupervisorTask -AppDir $moved -Configuration $installed
  Assert (!(Test-Path -LiteralPath $bindingFile)) 'stop can validate surviving task before binding is recreated'

  Remove-Item -LiteralPath $configFile
  Assert-Throws {Get-WidgetSupervisorTask $stableInfo} '*binding.json is missing*' 'missing binding without original install record is rejected'
  Assert (!(Test-WidgetStartupShortcutIdentity $stableShortcut $moved)) 'shortcut without any ownership record is rejected'
  foreach($foreign in @(
    @{appDir=$old;dataDir=$data;updateAgent=$isolatedAgent},
    @{appDir=$moved;dataDir=$data;updateAgent=(Join-Path $testRoot 'foreign-agent')},
    @{appDir=$moved;dataDir=(Join-Path $testRoot 'foreign-data');updateAgent=$isolatedAgent},
    @{appDir=$moved;dataDir=$data}
  )){
    Write-WidgetSupervisorJson $configFile $foreign
    Assert-Throws {Get-WidgetSupervisorTask $stableInfo} '*binding*' 'missing binding cannot claim mismatched installation paths'
  }
  Write-WidgetSupervisorJson $configFile $installed
  $stableTask.Actions[0].Execute=Join-Path $testRoot 'foreign.exe'
  Assert-Throws {Get-WidgetSupervisorTask $stableInfo} '*task action path mismatch*' 'missing binding recovery still rejects foreign task executable'
  $stableTask.Actions[0].Execute=$stableInfo.Execute
  $stableTask.Principal.UserId='S-1-5-18'
  Assert-Throws {Get-WidgetSupervisorTask $stableInfo} '*task owner mismatch*' 'missing binding recovery still rejects foreign task owner'
  $stableTask.Principal.UserId=$stableInfo.Sid

  Install-WidgetUpdateAgent $moved $data
  $repaired=Get-Content -LiteralPath $bindingFile -Raw -Encoding UTF8|ConvertFrom-Json
  Assert ($repaired.sid-eq $stableInfo.Sid -and $repaired.appDir-eq $moved -and $repaired.dataDir-eq $data) 'normal agent installation recreates binding with verified identity'
  Assert ([bool](Get-WidgetSupervisorTask $stableInfo)) 'surviving task validates against the recreated binding'
  Write-WidgetSupervisorJson $bindingFile @{sid=$stableInfo.Sid;appDir=$old;dataDir=$data}
  Assert-Throws {Get-WidgetSupervisorTask $stableInfo} '*Stable task binding mismatch*' 'existing foreign binding cannot fall back to installation record'
  Assert (!(Test-WidgetStartupShortcutIdentity $stableShortcut $moved)) 'existing foreign binding rejects stable shortcut'
  [IO.File]::WriteAllText($bindingFile,'{invalid json')
  Assert-Throws {Get-WidgetSupervisorTask $stableInfo} '*' 'malformed binding cannot fall back to installation record'
  Remove-Item -LiteralPath $bindingFile
  Install-WidgetUpdateAgent $moved $data

  $global:widgetInstallerTestTasks=@()
  $fakeCodex=Join-Path $testRoot 'codex-stub.cmd'
  [IO.File]::WriteAllText($fakeCodex,"@exit /b 0`r`n",[Text.UTF8Encoding]::new($false))
  $uninstallData=Join-Path $testRoot 'uninstall-deleted-state'
  Write-WidgetSupervisorJson $configFile @{appDir=$moved;dataDir=$uninstallData;codexPath=$fakeCodex;startupShortcut=(Join-Path $testRoot 'nonexistent.lnk')}
  & (Join-Path $moved 'Uninstall.ps1')|Out-Null
  $disabled=Get-Content -LiteralPath $configFile -Raw -Encoding UTF8|ConvertFrom-Json
  Assert ([bool]$disabled.disabledAt) 'successful uninstall records explicit disabled state'
  Assert (Test-Path -LiteralPath (Join-Path $uninstallData 'supervisor-disabled.flag')) 'uninstall tolerates removed preferences directory'
  $global:widgetInstallerTestSnapshot=[pscustomobject]@{ProcessId=2200;Name='powershell.exe';CreationDate=[DateTime]::UtcNow;CommandLine=('powershell.exe -File "'+(Join-Path $moved 'runtime\supervisor.ps1')+'"')}
  $global:widgetInstallerTestPolls=0
  $global:widgetInstallerTestProcessMode='delayed'
  function Get-CimInstance {
    param($ClassName,[string]$Filter)
    if($Filter.StartsWith('Name=')){return $global:widgetInstallerTestSnapshot}
    $global:widgetInstallerTestPolls++
    if($global:widgetInstallerTestProcessMode-eq 'delayed'){
      if($global:widgetInstallerTestPolls-le 2){return $global:widgetInstallerTestSnapshot}
      return $null
    }
    if($global:widgetInstallerTestProcessMode-eq 'reused'){
      return [pscustomobject]@{CreationDate=$global:widgetInstallerTestSnapshot.CreationDate.AddSeconds(1)}
    }
  }
  Stop-WidgetSupervisorTask $moved
  Assert ($global:widgetInstallerTestPolls-eq 3) 'stop waits for supervisor child after task disappears'
  $global:widgetInstallerTestPolls=0
  $global:widgetInstallerTestProcessMode='reused'
  Stop-WidgetSupervisorTask $moved
  Assert ($global:widgetInstallerTestPolls-eq 1) 'stop does not wait for a reused supervisor PID'
  $global:widgetInstallerTestPolls=0
  $global:widgetInstallerTestSnapshot.CommandLine='powershell.exe -File "C:\foreign\runtime\supervisor.ps1"'
  Stop-WidgetSupervisorTask $moved
  Assert ($global:widgetInstallerTestPolls-eq 0) 'stop ignores supervisors belonging to another directory'
  Write-WidgetSupervisorJson (Join-Path $uninstallData 'runtime.json') @{pid='invalid'}
  Stop-WidgetGui $moved $uninstallData
  Assert ($global:widgetInstallerTestPolls-eq 0) 'malformed runtime PID does not prevent stopping installation'
  Write-Output ("All $checks isolated installer assertions passed.")
}finally{
  $resolved=[IO.Path]::GetFullPath($testRoot)
  $tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
  if(!$resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved)-notlike 'gpt-niang-install-test-*'){throw 'Unsafe test cleanup path.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
