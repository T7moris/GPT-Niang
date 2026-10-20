function Get-WidgetInstallationDataDir {
  param([Parameter(Mandatory=$true)][string]$AppDir,[Parameter(Mandatory=$true)]$Configuration)
  if(![string]$Configuration.appDir -or ![string]$Configuration.dataDir){throw 'Installation paths are missing.'}
  $root=[IO.Path]::GetFullPath($AppDir).TrimEnd('\')
  $previousRoot=[IO.Path]::GetFullPath([string]$Configuration.appDir).TrimEnd('\')
  $data=[IO.Path]::GetFullPath([string]$Configuration.dataDir)
  if($previousRoot-ine $root){
    # A moved installation may retain its preferences, but a copied active one may not claim the same registration.
    if(Test-Path -LiteralPath $previousRoot){throw 'The original installation folder still exists. Disable and move it before reinstalling.'}
    $disabled=[bool]$Configuration.disabledAt -or (Test-Path -LiteralPath (Join-Path $data 'supervisor-disabled.flag'))
    if(!$disabled){throw 'Installation was moved without disabling it first.'}
  }
  return $data
}

function Read-WidgetSupervisorBinding {
  param([Parameter(Mandatory=$true)][string]$AppDir,[Parameter(Mandatory=$true)][string]$AgentDir)
  $bindingFile=Join-Path $AgentDir 'binding.json'
  if(Test-Path -LiteralPath $bindingFile){
    # An existing binding remains authoritative, including malformed or foreign ones.
    return (Get-Content -LiteralPath $bindingFile -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json)
  }
  # Preflight and stop run before Install-WidgetUpdateAgent recreates binding.json.
  # Recover identity from this installation's on-disk record without writing during
  # CheckOnly, and without allowing a fresh/copied folder to claim a stale task.
  $installationFile=Join-Path $AppDir 'installation.json'
  if(Test-Path -LiteralPath $installationFile){
    $installation=Get-Content -LiteralPath $installationFile -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json
    if([string]$installation.appDir -and [string]$installation.dataDir -and [string]$installation.updateAgent -and
       [IO.Path]::GetFullPath($installation.appDir).TrimEnd('\')-ieq [IO.Path]::GetFullPath($AppDir).TrimEnd('\') -and
       [IO.Path]::GetFullPath($installation.updateAgent).TrimEnd('\')-ieq [IO.Path]::GetFullPath($AgentDir).TrimEnd('\')){
      return [pscustomobject]@{sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;appDir=$installation.appDir;dataDir=$installation.dataDir}
    }
  }
  throw 'Stable launcher binding.json is missing and the original installation.json could not verify this installation. Restore the original installation record before reinstalling.'
}

function Test-WidgetStartupShortcutIdentity {
  param([Parameter(Mandatory=$true)]$Shortcut,[Parameter(Mandatory=$true)][string]$AppDir)
  $expectedExecute=Join-Path $env:WINDIR 'System32\wscript.exe'
  $expectedArguments='"'+(Join-Path ([IO.Path]::GetFullPath($AppDir)) 'launch.vbs')+'"'
  $stable=if(Get-Command Get-WidgetUpdateAgentDir -ErrorAction SilentlyContinue){Get-WidgetUpdateAgentDir}else{Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'GPTNiangUsage\update-agent'}
  $stableArguments='"'+(Join-Path $stable 'agent-launch.vbs')+'"'
  $argumentsMatch=[string]$Shortcut.Arguments-ieq $expectedArguments
  if([string]$Shortcut.Arguments-ieq $stableArguments){
    try{$binding=Read-WidgetSupervisorBinding -AppDir $AppDir -AgentDir $stable
      $argumentsMatch=$binding.sid-eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -and [IO.Path]::GetFullPath($binding.appDir)-ieq [IO.Path]::GetFullPath($AppDir)
    }catch{$argumentsMatch=$false}
  }
  return [bool]($Shortcut.TargetPath -and [IO.Path]::GetFullPath([string]$Shortcut.TargetPath)-ieq $expectedExecute -and $argumentsMatch)
}

function Stop-WidgetGui {
  param([Parameter(Mandatory=$true)][string]$AppDir,[Parameter(Mandatory=$true)][string]$DataDir)
  $null=New-Item -ItemType Directory -Path $DataDir -Force
  $stopFile=Join-Path $DataDir 'stop.flag'
  $runtime=$null
  try{$runtime=Get-Content -LiteralPath (Join-Path $DataDir 'runtime.json') -Raw -Encoding UTF8|ConvertFrom-Json}catch{}
  $guiPid=0
  if(!$runtime -or ![int]::TryParse([string]$runtime.pid,[ref]$guiPid) -or $guiPid-le 0){
    # runtime.json is written late in startup. A GUI that is still between
    # start-widget.ps1 and that write would otherwise keep running after the
    # stop request (and delete stop.flag itself), leaving an unsupervised pet.
    $expectedStart='"'+(Join-Path $AppDir 'runtime\start-widget.ps1')+'"'
    $expectedWidget='"'+(Join-Path $AppDir 'widget.ps1')+'"'
    $launching=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop|Where-Object{
      $_.ProcessId-ne $PID -and [string]$_.CommandLine -and ($_.CommandLine.IndexOf($expectedStart,[StringComparison]::OrdinalIgnoreCase)-ge 0 -or $_.CommandLine.IndexOf($expectedWidget,[StringComparison]::OrdinalIgnoreCase)-ge 0)
    })
    # Do not leave a stop request behind when there is nothing to stop: the
    # next normal launch would otherwise be swallowed by that stale flag.
    if(!$launching.Count){Remove-Item -LiteralPath $stopFile -ErrorAction SilentlyContinue;return}
    [IO.File]::WriteAllText($stopFile,'stop')
    $deadline=[DateTime]::UtcNow.AddSeconds(6)
    do{
      $alive=@($launching|Where-Object{
        $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$_.ProcessId) -ErrorAction SilentlyContinue
        $current -and $current.CreationDate-eq $_.CreationDate
      })
      if(!$alive.Count){Remove-Item -LiteralPath $stopFile -ErrorAction SilentlyContinue;return}
      Start-Sleep -Milliseconds 100
    }while([DateTime]::UtcNow-lt $deadline)
    throw 'The starting widget did not stop within 6 seconds.'
  }
  $process=Get-CimInstance Win32_Process -Filter ('ProcessId='+$guiPid) -ErrorAction Stop
  $expectedGui='"'+(Join-Path $AppDir 'widget.ps1')+'"'
  if(!$process -or $process.Name-notin @('powershell.exe','pwsh.exe') -or ![string]$process.CommandLine -or $process.CommandLine.IndexOf($expectedGui,[StringComparison]::OrdinalIgnoreCase)-lt 0){Remove-Item -LiteralPath $stopFile -ErrorAction SilentlyContinue;return}
  [IO.File]::WriteAllText($stopFile,'stop')
  $deadline=[DateTime]::UtcNow.AddSeconds(6)
  do{
    $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+$guiPid) -ErrorAction Stop
    # Do not wait for an unrelated process that reused the previous GUI's PID.
    if(!$current -or $current.CreationDate-ne $process.CreationDate){Remove-Item -LiteralPath $stopFile -ErrorAction SilentlyContinue;return}
    Start-Sleep -Milliseconds 100
  }while([DateTime]::UtcNow-lt $deadline)
  throw 'The previous widget did not stop within 6 seconds.'
}

function Get-WidgetSupervisorInfo {
  param([Parameter(Mandatory=$true)][string]$AppDir,$Configuration=$null)
  $root=[IO.Path]::GetFullPath($AppDir).TrimEnd('\')
  $config=$Configuration
  if(!$config){$config=Get-Content -LiteralPath (Join-Path $root 'installation.json') -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json}
  if(![string]$config.appDir -or ![string]$config.dataDir){throw 'Installation paths are missing.'}
  if([IO.Path]::GetFullPath([string]$config.appDir).TrimEnd('\')-ine $root){throw 'Supervisor installation identity mismatch.'}
  $data=[IO.Path]::GetFullPath([string]$config.dataDir)
  $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $agent=if(Get-Command Get-WidgetUpdateAgentDir -ErrorAction SilentlyContinue){Get-WidgetUpdateAgentDir}elseif($config.updateAgent){[IO.Path]::GetFullPath($config.updateAgent)}else{Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'GPTNiangUsage\update-agent'}
  if($config.updateAgent -and [IO.Path]::GetFullPath($config.updateAgent)-ine $agent){throw 'Stable launcher path mismatch.'}
  $stable=[bool]$config.updateAgent
  $entry=Join-Path $agent 'update-agent.ps1'
  $diagnostic=Join-Path $agent 'supervisor-entry-error.txt'
  $entryCommand="try { & '"+$entry.Replace("'","''")+"' -Supervisor } catch { [IO.File]::WriteAllText('"+$diagnostic.Replace("'","''")+"',"+'$_.Exception.ToString()); exit 1 }'
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($entryCommand))
  [pscustomobject]@{AppDir=$root;DataDir=$data;Sid=$sid;TaskName=('GPT Niang Usage - '+$sid);TaskPath='\';Execute=$(if($stable){Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'}else{Join-Path $env:WINDIR 'System32\wscript.exe'});Arguments=$(if($stable){'-NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand '+$encoded}else{'"'+(Join-Path $root 'supervisor.vbs')+'"'});WorkingDirectory=$(if($stable){$agent}else{$root});AgentDir=$agent}
}

function Resolve-WidgetSupervisorSid([string]$Identity){
  if($Identity-match '^S-\d-') {return ([Security.Principal.SecurityIdentifier]::new($Identity)).Value}
  return ([Security.Principal.NTAccount]::new($Identity)).Translate([Security.Principal.SecurityIdentifier]).Value
}

function Assert-WidgetSupervisorTaskIdentity {
  param([Parameter(Mandatory=$true)]$Task,[Parameter(Mandatory=$true)]$Info)
  if($Task.TaskName-ine $Info.TaskName -or $Task.TaskPath-ine $Info.TaskPath){throw 'Supervisor task name mismatch.'}
  if((Resolve-WidgetSupervisorSid ([string]$Task.Principal.UserId))-ne $Info.Sid){throw 'Supervisor task owner mismatch.'}
  if([string]$Task.Principal.LogonType-notin @('Interactive','3') -or [string]$Task.Principal.RunLevel-notin @('Limited','0')){throw 'Supervisor task privilege mismatch.'}
  $actions=@($Task.Actions)
  if($actions.Count-ne 1){throw 'Supervisor task action count mismatch.'}
  $action=$actions[0]
  $legacyArguments='"'+(Join-Path $Info.AppDir 'supervisor.vbs')+'"'
  $wscript=Join-Path $env:WINDIR 'System32\wscript.exe'
  $legacy=[string]$action.Arguments -ieq $legacyArguments -and [IO.Path]::GetFullPath([string]$action.WorkingDirectory).TrimEnd('\') -ieq $Info.AppDir -and [IO.Path]::GetFullPath([string]$action.Execute) -ieq $wscript
  $logicalAgent=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'GPTNiangUsage\update-agent'
  $oldStableArguments=@(('"'+(Join-Path $Info.AgentDir 'agent-supervisor.vbs')+'"'),('"'+(Join-Path $logicalAgent 'agent-supervisor.vbs')+'"'))
  $oldStable=$oldStableArguments -icontains [string]$action.Arguments -and @($Info.AgentDir,$logicalAgent) -icontains [IO.Path]::GetFullPath([string]$action.WorkingDirectory).TrimEnd('\') -and [IO.Path]::GetFullPath([string]$action.Execute) -ieq $wscript
  $current=[string]$action.Arguments -ieq $Info.Arguments -and [IO.Path]::GetFullPath([string]$action.WorkingDirectory).TrimEnd('\') -ieq $Info.WorkingDirectory -and [IO.Path]::GetFullPath([string]$action.Execute) -ieq $Info.Execute
  if(($current -and $Info.WorkingDirectory -ine $Info.AppDir) -or $oldStable){
    $binding=Read-WidgetSupervisorBinding -AppDir $Info.AppDir -AgentDir $Info.AgentDir
    if($binding.sid-ne $Info.Sid -or [IO.Path]::GetFullPath($binding.appDir)-ine $Info.AppDir -or [IO.Path]::GetFullPath($binding.dataDir)-ine $Info.DataDir){throw 'Stable task binding mismatch.'}
  }
  if(!($legacy -or $current -or $oldStable)){throw 'Supervisor task action path mismatch.'}
}

function Get-WidgetSupervisorTask {
  param([Parameter(Mandatory=$true)]$Info)
  $tasks=@(Get-ScheduledTask -TaskPath $Info.TaskPath -ErrorAction Stop|Where-Object{$_.TaskName-eq $Info.TaskName})
  if($tasks.Count-gt 1){throw 'Multiple supervisor tasks found.'}
  if($tasks.Count-eq 1){Assert-WidgetSupervisorTaskIdentity $tasks[0] $Info;return $tasks[0]}
  return $null
}

function Write-WidgetSupervisorJson([string]$File,$Value){
  $null=New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($File)) -Force
  $temp=$File+'.'+$PID+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
  try{
    [IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    if([IO.File]::Exists($File)){[IO.File]::Replace($temp,$File,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temp,$File)}
  }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}

function Set-WidgetSupervisorPause {
  param([Parameter(Mandatory=$true)][string]$AppDir,[long]$HostHandle=0,[int]$HostPid=0)
  $info=Get-WidgetSupervisorInfo $AppDir
  if($HostHandle-le 0){try{$presence=Get-Content -LiteralPath (Join-Path $info.DataDir 'presence.json') -Raw -Encoding UTF8|ConvertFrom-Json;$HostHandle=[long]$presence.host}catch{}}
  if($HostHandle-gt 0 -and $HostPid-le 0){
    if(!('GptWidgetSupervisorPauseNative' -as [type])){Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class GptWidgetSupervisorPauseNative {
 [DllImport("user32.dll")]static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 public static int ProcessId(IntPtr h){uint pid;GetWindowThreadProcessId(h,out pid);return (int)pid;}
}
'@}
    $HostPid=[GptWidgetSupervisorPauseNative]::ProcessId([IntPtr]$HostHandle)
  }
  $started=0L
  if($HostPid-gt 0){try{$started=(Get-Process -Id $HostPid -ErrorAction Stop).StartTime.ToUniversalTime().Ticks}catch{}}
  Write-WidgetSupervisorJson (Join-Path $info.DataDir 'supervisor-pause.json') @{host=$HostHandle;hostPid=$HostPid;hostStarted=$started;at=[DateTime]::UtcNow.ToString('o')}
}

function Resume-WidgetSupervisor {
  param([Parameter(Mandatory=$true)][string]$AppDir)
  $info=Get-WidgetSupervisorInfo $AppDir
  foreach($name in @('supervisor-pause.json','supervisor-disabled.flag','supervisor-stop.flag')){
    $file=Join-Path $info.DataDir $name
    if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -ErrorAction Stop}
  }
}

function Disable-WidgetSupervisor {
  param([Parameter(Mandatory=$true)][string]$AppDir)
  $info=Get-WidgetSupervisorInfo $AppDir
  $null=New-Item -ItemType Directory -Path $info.DataDir -Force
  [IO.File]::WriteAllText((Join-Path $info.DataDir 'supervisor-disabled.flag'),'disabled')
}

function New-WidgetSupervisorTaskDefinition {
  param([Parameter(Mandatory=$true)]$Info)
  $action=New-ScheduledTaskAction -Execute $Info.Execute -Argument $Info.Arguments -WorkingDirectory $Info.WorkingDirectory
  $principal=New-ScheduledTaskPrincipal -UserId $Info.Sid -LogonType Interactive -RunLevel Limited
  $trigger=New-ScheduledTaskTrigger -AtLogOn -User $Info.Sid
  $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable -Hidden -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(1))
  New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Settings $settings -Description 'Keep the local GPT Niang widget attached to the current user Codex main window.'
}

function Register-WidgetSupervisorTask {
  param([Parameter(Mandatory=$true)][string]$AppDir)
  $info=Get-WidgetSupervisorInfo $AppDir
  foreach($relative in @('supervisor.vbs','runtime\supervisor.ps1','widget.ps1')){if(!(Test-Path -LiteralPath (Join-Path $info.AppDir $relative))){throw "Missing supervisor file: $relative"}}
  $existing=Get-WidgetSupervisorTask $info
  if($existing -and [string]$existing.State-eq 'Running'){Stop-WidgetSupervisorTask $AppDir}
  Resume-WidgetSupervisor $AppDir
  $currentAction=if($existing){@($existing.Actions)[0]}else{$null}
  # An unchanged stable entry survives program replacement. Replacing the running
  # recovery task's definition can terminate its own instance on Windows.
  if(!$currentAction -or [string]$currentAction.Arguments-ine $info.Arguments -or [IO.Path]::GetFullPath($currentAction.WorkingDirectory).TrimEnd('\')-ine $info.WorkingDirectory){
    $definition=New-WidgetSupervisorTaskDefinition $info
    Register-ScheduledTask -TaskName $info.TaskName -TaskPath $info.TaskPath -InputObject $definition -Force -ErrorAction Stop|Out-Null
  }elseif([int]$existing.Settings.RestartCount-ne 3 -or [string]$existing.Settings.RestartInterval-ne 'PT1M'){
    # Migrate retry settings without replacing the stable entry/action.
    $definition=New-WidgetSupervisorTaskDefinition $info
    Set-ScheduledTask -TaskName $info.TaskName -TaskPath $info.TaskPath -Settings $definition.Settings -ErrorAction Stop|Out-Null
  }
  $registered=Get-WidgetSupervisorTask $info
  if(!$registered){throw 'Supervisor task registration not confirmed.'}
  # IgnoreNew handles a running recovery instance; the CIM state can lag a stop.
  Start-ScheduledTask -TaskName $info.TaskName -TaskPath $info.TaskPath -ErrorAction Stop
  return $info
}

function Start-WidgetSupervisorTask {
  param([Parameter(Mandatory=$true)][string]$AppDir)
  $info=Get-WidgetSupervisorInfo $AppDir
  $task=Get-WidgetSupervisorTask $info
  if(!$task){throw 'Supervisor task is not installed.'}
  Resume-WidgetSupervisor $AppDir
  Start-ScheduledTask -TaskName $info.TaskName -TaskPath $info.TaskPath -ErrorAction Stop
}

function Stop-WidgetSupervisorTask {
  param([Parameter(Mandatory=$true)][string]$AppDir,$Configuration=$null)
  $info=Get-WidgetSupervisorInfo $AppDir $Configuration
  $task=Get-WidgetSupervisorTask $info
  # Task state alone does not prove its child PowerShell has exited.
  $expectedScript='"'+(Join-Path $info.AppDir 'runtime\supervisor.ps1')+'"'
  $stableScript='"'+(Join-Path $info.AgentDir 'update-agent.ps1')+'"'
  $self=$null
  if($info.WorkingDirectory-ine $info.AppDir){$self=Get-CimInstance Win32_Process -Filter ('ProcessId='+$PID) -ErrorAction Stop}
  # Logon recovery runs inside the scheduled entry before its supervisor loop.
  # It must not terminate its own task while re-registering the recovered plugin.
  $encodedEntry=$info.Arguments-match '-EncodedCommand\s' -and $self -and [string]$self.CommandLine -and $self.CommandLine.IndexOf($info.Arguments,[StringComparison]::OrdinalIgnoreCase)-ge 0
  $recoveringEntry=$encodedEntry -or ($self -and [string]$self.CommandLine -and $self.CommandLine.IndexOf($stableScript,[StringComparison]::OrdinalIgnoreCase)-ge 0 -and $self.CommandLine-match '\s-Supervisor(?:\s|$)')
  $processes=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop|Where-Object{
    $_.ProcessId-ne $PID -and [string]$_.CommandLine -and ($_.CommandLine.IndexOf($expectedScript,[StringComparison]::OrdinalIgnoreCase)-ge 0 -or ($info.WorkingDirectory-ine $info.AppDir -and ($_.CommandLine.IndexOf($stableScript,[StringComparison]::OrdinalIgnoreCase)-ge 0 -or ($info.Arguments-match '-EncodedCommand\s' -and $_.CommandLine.IndexOf($info.Arguments,[StringComparison]::OrdinalIgnoreCase)-ge 0))))
  })
  $null=New-Item -ItemType Directory -Path $info.DataDir -Force
  [IO.File]::WriteAllText((Join-Path $info.DataDir 'supervisor-stop.flag'),'stop')
  if($task -and [string]$task.State-eq 'Running' -and !$recoveringEntry){
    Stop-ScheduledTask -TaskName $info.TaskName -TaskPath $info.TaskPath -ErrorAction Stop
  }
  $deadline=[DateTime]::UtcNow.AddSeconds(6)
  do{
    $running=$false
    if($task){
      $stopped=Get-ScheduledTask -TaskName $info.TaskName -TaskPath $info.TaskPath -ErrorAction Stop
      Assert-WidgetSupervisorTaskIdentity $stopped $info
      $running=[string]$stopped.State-eq 'Running' -and !$recoveringEntry
    }
    foreach($process in $processes){
      $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$process.ProcessId) -ErrorAction Stop
      if($current -and $current.CreationDate-eq $process.CreationDate){$running=$true}
    }
    if(!$running){return}
    Start-Sleep -Milliseconds 150
  }while([DateTime]::UtcNow-lt $deadline)
  throw 'Supervisor did not stop within 6 seconds.'
}

function Unregister-WidgetSupervisorTask {
  param([Parameter(Mandatory=$true)][string]$AppDir)
  $info=Get-WidgetSupervisorInfo $AppDir
  $task=Get-WidgetSupervisorTask $info
  Disable-WidgetSupervisor $AppDir
  Stop-WidgetSupervisorTask $AppDir
  if($task){Unregister-ScheduledTask -TaskName $info.TaskName -TaskPath $info.TaskPath -Confirm:$false -ErrorAction Stop}
}
