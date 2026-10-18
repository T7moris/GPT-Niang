$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
. (Join-Path $source 'runtime\supervisor-task.ps1')
. (Join-Path $source 'runtime\update-common.ps1')
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-install-test-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot
$checks=0
function Assert($condition,[string]$label){if(!$condition){throw ('Assertion failed: '+$label)};$script:checks++;Write-Output ('PASS '+$label)}
function Assert-Throws([scriptblock]$action,[string]$pattern,[string]$label){try{& $action|Out-Null}catch{Assert ($_.Exception.Message-like $pattern) $label;return};throw ('Expected rejection: '+$label)}
try{
  $expectedStorage=Join-Path ([Environment]::GetFolderPath('UserProfile')) '.gpt-niang'
  Assert ((Get-WidgetStorageRoot)-eq $expectedStorage) 'storage root belongs to the user profile outside redirected LocalAppData'
  Assert ((Get-WidgetUpdateAgentDir)-eq (Join-Path $expectedStorage 'update-agent')) 'stable launcher uses the same profile storage root'
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
  $common=$common.Replace("(Join-Path (Get-WidgetStorageRoot) 'update-agent')",("'"+$isolatedAgent.Replace("'","''")+"'"))
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

  $readyInfo=Get-WidgetSupervisorInfo $moved @{appDir=$moved;dataDir=$uninstallData}
  $started=[DateTime]::UtcNow.AddSeconds(-5)
  $global:widgetInstallerReadyProcess=[pscustomobject]@{Name='powershell.exe';CreationDate=$started;CommandLine=('powershell.exe -File "'+(Join-Path $moved 'runtime\supervisor.ps1')+'"')}
  function Get-CimInstance {return $global:widgetInstallerReadyProcess}
  $statusFile=Join-Path $uninstallData 'supervisor-status.json'
  $heartbeat=@{pid=2200;processStartedAt=$started.ToString('o');at=[DateTime]::UtcNow.ToString('o');taskName=$readyInfo.TaskName}
  Write-WidgetSupervisorJson $statusFile $heartbeat
  Assert (Test-WidgetSupervisorReady $readyInfo) 'a fresh heartbeat from the installed supervisor is ready'
  $global:widgetInstallerReadyProcess.CreationDate=$started.AddTicks(-4)
  Assert (Test-WidgetSupervisorReady $readyInfo) 'CIM microsecond truncation preserves the same supervisor identity'
  $global:widgetInstallerReadyProcess.CreationDate=$started
  $stableInfo=Get-WidgetSupervisorInfo $moved @{appDir=$moved;dataDir=$uninstallData;updateAgent=(Get-WidgetUpdateAgentDir)}
  $global:widgetInstallerReadyProcess.CommandLine='powershell.exe -File "'+(Join-Path $stableInfo.AgentDir 'update-agent.ps1')+'" -Supervisor'
  Assert (Test-WidgetSupervisorReady $stableInfo) 'the bound stable supervisor entry can satisfy readiness'
  $global:widgetInstallerReadyProcess.CommandLine='powershell.exe -File "'+(Join-Path $stableInfo.AgentDir 'update-agent.ps1')+'"'
  Assert (!(Test-WidgetSupervisorReady $stableInfo)) 'a one-shot launcher cannot impersonate a running supervisor'
  $global:widgetInstallerReadyProcess.CommandLine='powershell.exe -File "C:\foreign\runtime\supervisor.ps1"'
  Assert (!(Test-WidgetSupervisorReady $stableInfo)) 'a foreign supervisor cannot satisfy startup readiness'
  $global:widgetInstallerReadyProcess.CommandLine='powershell.exe -File "'+(Join-Path $moved 'runtime\supervisor.ps1')+'"'
  $global:widgetInstallerReadyProcess.CreationDate=$started.AddSeconds(1)
  Assert (!(Test-WidgetSupervisorReady $readyInfo)) 'a reused supervisor PID cannot satisfy readiness'
  $global:widgetInstallerReadyProcess.CreationDate=$started
  $heartbeat.at=[DateTime]::UtcNow.AddMinutes(-1).ToString('o')
  Write-WidgetSupervisorJson $statusFile $heartbeat
  Assert (!(Test-WidgetSupervisorReady $readyInfo)) 'a stale supervisor heartbeat cannot claim startup success'
  function Get-ScheduledTaskInfo {return @{LastTaskResult=2147942667}}
  Assert-Throws {Wait-WidgetSupervisorReady $readyInfo -TimeoutSeconds 0} '*0x8007010B*' 'failed startup reports the real scheduler result'

  function New-ScheduledTaskAction {param($Execute,$Argument,$WorkingDirectory);return @{Execute=$Execute;Arguments=$Argument;WorkingDirectory=$WorkingDirectory}}
  function New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel);return @{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel}}
  function New-ScheduledTaskTrigger {
    param([switch]$AtLogOn,$User,[switch]$Once,$At,$RepetitionInterval)
    if($Once){return @{CimClass=@{CimClassName='MSFT_TaskTimeTrigger'};Enabled=$true;StartBoundary=$At;Repetition=@{Interval='PT1M';Duration=$null};RequestedInterval=$RepetitionInterval}}
    return @{CimClass=@{CimClassName='MSFT_TaskLogonTrigger'};Enabled=$true;User=$User}
  }
  function New-ScheduledTaskSettingsSet {
    param([switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,$ExecutionTimeLimit,$MultipleInstances,[switch]$StartWhenAvailable,[switch]$Hidden,$RestartCount,$RestartInterval)
    return @{RestartCount=$RestartCount;RestartInterval=$RestartInterval;ExecutionTimeLimit=$ExecutionTimeLimit;MultipleInstances=$MultipleInstances}
  }
  function New-ScheduledTask {param($Action,$Principal,$Trigger,$Settings,$Description);return @{Actions=@($Action);Principal=$Principal;Triggers=@($Trigger);Settings=$Settings}}
  $definition=New-WidgetSupervisorTaskDefinition $stableInfo
  Assert ($definition.Settings.RestartCount-eq 999 -and $definition.Settings.RestartInterval-eq [TimeSpan]::FromMinutes(1)) 'scheduler retries an unexpectedly exited supervisor'
  Assert ($definition.Settings.ExecutionTimeLimit-eq [TimeSpan]::Zero -and $definition.Settings.MultipleInstances-eq 'IgnoreNew') 'supervisor stays running without duplicate scheduled instances'
  Assert ($definition.Triggers.Count-eq 2 -and $definition.Triggers[0].CimClass.CimClassName-eq 'MSFT_TaskLogonTrigger') 'supervisor retains its per-user logon trigger'
  Assert ((Test-WidgetSupervisorPeriodicTrigger $definition) -and $definition.Triggers[1].RequestedInterval-eq [TimeSpan]::FromMinutes(1)) 'supervisor has an indefinite one-minute recovery trigger'
  $definition.Triggers[1].Repetition.Duration='PT1H'
  Assert (!(Test-WidgetSupervisorPeriodicTrigger $definition)) 'a recovery trigger that expires is not accepted'
  $definition.Triggers[1].Repetition.Duration=$null

  Write-WidgetSupervisorJson $configFile @{appDir=$moved;dataDir=$uninstallData;updateAgent=$stableInfo.AgentDir}
  $global:widgetInstallerRegistrationTask=@{TaskName=$stableInfo.TaskName;TaskPath=$stableInfo.TaskPath;State='Ready';Actions=$definition.Actions;Triggers=@($definition.Triggers[0]);Settings=@{RestartCount=999;RestartInterval='PT1M'}}
  $global:widgetInstallerRegistrations=0
  function Get-WidgetSupervisorTask {return $global:widgetInstallerRegistrationTask}
  function Register-ScheduledTask {
    param($TaskName,$TaskPath,$InputObject,[switch]$Force,$ErrorAction)
    $global:widgetInstallerRegistrations++
    $global:widgetInstallerRegistrationTask.Triggers=$InputObject.Triggers
    $global:widgetInstallerRegistrationTask.Settings=@{RestartCount=$InputObject.Settings.RestartCount;RestartInterval='PT1M'}
  }
  function Start-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)}
  $global:widgetInstallerReadyProcess.CommandLine='powershell.exe -File "'+(Join-Path $moved 'runtime\supervisor.ps1')+'"'
  $null=Register-WidgetSupervisorTask $moved
  Assert ($global:widgetInstallerRegistrations-eq 1 -and (Test-WidgetSupervisorPeriodicTrigger $global:widgetInstallerRegistrationTask)) 'normal installation upgrades an existing task recovery trigger'
  $null=Register-WidgetSupervisorTask $moved
  Assert ($global:widgetInstallerRegistrations-eq 1) 'an unchanged scheduled definition is retained'
  $global:widgetInstallerRegistrationTask.Triggers=@($definition.Triggers[0])
  $global:widgetInstallerReadyProcess.CommandLine='powershell.exe -File "'+(Join-Path $stableInfo.AgentDir 'update-agent.ps1')+'" -Supervisor'
  $null=Register-WidgetSupervisorTask $moved
  Assert ($global:widgetInstallerRegistrations-eq 1) 'self recovery defers rewriting its own scheduled definition'
  Write-Output ("All $checks isolated installer assertions passed.")
}finally{
  $resolved=[IO.Path]::GetFullPath($testRoot)
  $tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
  if(!$resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved)-notlike 'gpt-niang-install-test-*'){throw 'Unsafe test cleanup path.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
