function Get-WidgetPhysicalFilePath([string]$File) {
  if(!('GptWidgetPhysicalPath' -as [type])){
    Add-Type -TypeDefinition 'using System;using System.Text;using System.Runtime.InteropServices;public static class GptWidgetPhysicalPath{[DllImport("kernel32.dll",CharSet=CharSet.Unicode)]public static extern uint GetFinalPathNameByHandle(IntPtr h,StringBuilder s,uint n,uint f);}'
  }
  $stream=[IO.File]::OpenRead($File)
  try{
    $buffer=[Text.StringBuilder]::new(4096)
    if([GptWidgetPhysicalPath]::GetFinalPathNameByHandle($stream.SafeFileHandle.DangerousGetHandle(),$buffer,4096,0)-eq 0){throw 'Cannot resolve physical installation path.'}
    $result=$buffer.ToString();if($result.StartsWith('\\?\')){$result=$result.Substring(4)}
    return $result
  }finally{$stream.Dispose()}
}
function Get-WidgetUpdateAgentDir {
  $logical=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'GPTNiangUsage\update-agent'
  $candidates=@($PSScriptRoot,$logical)
  $installed=Join-Path (Split-Path $PSScriptRoot -Parent) 'installation.json'
  if(Test-Path -LiteralPath $installed){try{$cfg=Get-Content -LiteralPath $installed -Raw -Encoding UTF8|ConvertFrom-Json;if($cfg.updateAgent){$candidates=@($cfg.updateAgent)+$candidates}}catch{}}
  foreach($candidate in $candidates){
    if(!$candidate){continue};$binding=Join-Path $candidate 'binding.json'
    if(Test-Path -LiteralPath $binding){return (Split-Path (Get-WidgetPhysicalFilePath $binding) -Parent)}
  }
  return $logical
}
function Read-WidgetUpdateJson([string]$File) {
  if(Test-Path -LiteralPath $File){return (Get-Content -LiteralPath $File -Raw -Encoding UTF8|ConvertFrom-Json)}
  return $null
}
function Get-WidgetFileHash([string]$File) {
  $stream=[IO.File]::OpenRead($File)
  $sha=[Security.Cryptography.SHA256]::Create()
  try{return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')}
  finally{$sha.Dispose();$stream.Dispose()}
}
function Enter-WidgetUpdateLock {
  param([string]$AgentDir=(Get-WidgetUpdateAgentDir),[string]$Token,[int]$OwnerPid=$PID)
  $null=New-Item -ItemType Directory -Path $AgentDir -Force
  $lockDir=Join-Path $AgentDir 'update.lock'
  if($Token){
    $owner=Read-WidgetUpdateJson (Join-Path $lockDir 'owner.json')
    if(!$owner -or $owner.token-ne $Token){throw 'Update lock token mismatch.'}
    if($owner.helperPid -and [int]$owner.helperPid-ne $PID){throw 'Update lock is owned by another helper.'}
    $claimed=!$owner.helperPid
    $owner|Add-Member helperPid $PID -Force
    Write-WidgetSupervisorJson (Join-Path $lockDir 'owner.json') $owner
    return [pscustomobject]@{Directory=$lockDir;Token=$Token;Owned=$false;HelperClaimed=$claimed}
  }
  if($OwnerPid-le 0 -or !(Get-Process -Id $OwnerPid -ErrorAction SilentlyContinue)){throw 'Update lock owner is unavailable.'}
  # Serialize stale reclamation across Node and PowerShell. A second reclaimer
  # must re-read the owner after the first one has published its new lock.
  $sha=[Security.Cryptography.SHA256]::Create()
  try{$key=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($AgentDir).TrimEnd('\').ToLowerInvariant()))).Replace('-','')}
  finally{$sha.Dispose()}
  $mutex=[Threading.Mutex]::new($false,('Global\GPTNiangUpdateReclaim-'+$key));$held=$false
  try {
    try{$held=$mutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$held=$true}
    if(!$held){throw 'Update lock reclamation is busy.'}
    if(Test-Path -LiteralPath $lockDir){
      $owner=Read-WidgetUpdateJson (Join-Path $lockDir 'owner.json')
      $running=@(foreach($id in @($owner.pid,$owner.helperPid)){if($id -and (Get-Process -Id ([int]$id) -ErrorAction SilentlyContinue)){$id}})
      if($running.Count -or (!$owner -and [DateTime]::UtcNow-(Get-Item -LiteralPath $lockDir).LastWriteTimeUtc-lt [TimeSpan]::FromMinutes(1))){throw 'An update or installation is already running.'}
      [IO.Directory]::Move($lockDir,($lockDir+'.stale-'+[Guid]::NewGuid().ToString('N')))
    }
    # Fresh Node claims can appear after the stale directory was renamed. Never
    # overwrite one: CreateDirectory via New-Item without Force rejects it.
    $null=New-Item -ItemType Directory -Path $lockDir -ErrorAction Stop
    $token=[Guid]::NewGuid().ToString('D')
    Write-WidgetSupervisorJson (Join-Path $lockDir 'owner.json') @{pid=$OwnerPid;token=$token;at=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()}
    return [pscustomobject]@{Directory=$lockDir;Token=$token;Owned=$true}
  } finally {if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function Exit-WidgetUpdateLock($Lock) {
  if(!$Lock){return}
  $owner=Read-WidgetUpdateJson (Join-Path $Lock.Directory 'owner.json')
  if(!$Lock.Owned){
    if($Lock.HelperClaimed -and $owner.token-eq $Lock.Token -and $owner.helperPid-eq $PID){
      $owner.PSObject.Properties.Remove('helperPid')
      Write-WidgetSupervisorJson (Join-Path $Lock.Directory 'owner.json') $owner
    }
    return
  }
  if($owner.token-eq $Lock.Token){
    $physicalLock=Split-Path (Get-WidgetPhysicalFilePath (Join-Path $Lock.Directory 'owner.json')) -Parent
    Assert-WidgetUpdateChildPath $physicalLock (Get-WidgetUpdateAgentDir)
    Remove-Item -LiteralPath $physicalLock -Recurse -Force
  }
}
function Assert-WidgetUpdateChildPath([string]$Path,[string]$Parent) {
  $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
  $base=[IO.Path]::GetFullPath($Parent).TrimEnd('\')+'\'
  if(!$full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'Update path escaped its expected directory.'}
  return
}
function Assert-WidgetUpdateBinding([string]$AppDir,[string]$DataDir,[string]$AgentDir=(Get-WidgetUpdateAgentDir)) {
  $binding=Read-WidgetUpdateJson (Join-Path $AgentDir 'binding.json')
  $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  if(!$binding -or $binding.sid-ne $sid -or [IO.Path]::GetFullPath($binding.appDir)-ine [IO.Path]::GetFullPath($AppDir) -or [IO.Path]::GetFullPath($binding.dataDir)-ine [IO.Path]::GetFullPath($DataDir)){throw 'Stable update launcher identity mismatch.'}
  return $binding
}
function Install-WidgetUpdateAgent([string]$AppDir,[string]$DataDir) {
  $agentDir=Get-WidgetUpdateAgentDir
  Assert-WidgetUpdateChildPath $AppDir (Split-Path $AppDir -Parent)
  $old=Read-WidgetUpdateJson (Join-Path $agentDir 'binding.json')
  if($old -and $old.appDir-ine $AppDir -and (Test-Path -LiteralPath $old.appDir)){throw 'Stable launcher belongs to an existing installation.'}
  $null=New-Item -ItemType Directory -Path $agentDir -Force
  foreach($file in @('update-agent.ps1','update-helper.ps1','update-common.ps1','update-lock.ps1','supervisor-task.ps1','install-preflight.ps1','agent-launch.vbs','agent-supervisor.vbs')) {
    $bytes=[IO.File]::ReadAllBytes((Join-Path $AppDir ('runtime\'+$file)))
    $target=Join-Path $agentDir $file
    # Keep a complete file visible to launchers, including during a failed upgrade.
    $temp=$target+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllBytes($temp,$bytes)
    if([IO.File]::Exists($target)){[IO.File]::Replace($temp,$target,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temp,$target)}
  }
  Write-WidgetSupervisorJson (Join-Path $agentDir 'binding.json') @{sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;appDir=$AppDir;dataDir=$DataDir}
}
