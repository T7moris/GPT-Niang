function Get-WidgetKnownFolderPath([Guid]$Id){
  if(!('GptWidgetKnownFolders' -as [type])){
    Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class GptWidgetKnownFolders {
 [DllImport("shell32.dll")]static extern int SHGetKnownFolderPath(ref Guid id,uint flags,IntPtr token,out IntPtr path);
 public static string Read(Guid id){
  IntPtr value=IntPtr.Zero;
  try{Marshal.ThrowExceptionForHR(SHGetKnownFolderPath(ref id,0x10000,IntPtr.Zero,out value));return Marshal.PtrToStringUni(value);}
  finally{if(value!=IntPtr.Zero)Marshal.FreeCoTaskMem(value);}
 }
}
'@
  }
  # KF_FLAG_NO_PACKAGE_REDIRECTION gives Task Scheduler and Explorer the same
  # physical location as the installer, including Store-hosted Codex sessions.
  return [GptWidgetKnownFolders]::Read($Id)
}
function Get-WidgetLocalApplicationData {
  return Get-WidgetKnownFolderPath ([Guid]'F1B32785-6FBA-4FCF-9D55-7B8E7F157091')
}
function Get-WidgetUpdateAgentDir {
  return (Join-Path (Get-WidgetLocalApplicationData) 'GPTNiangUsage\update-agent')
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
    Assert-WidgetUpdateChildPath $Lock.Directory (Get-WidgetUpdateAgentDir)
    Remove-Item -LiteralPath $Lock.Directory -Recurse -Force
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
function Install-WidgetSupervisorHost([string]$AppDir,[string]$AgentDir) {
  $source=Join-Path $AppDir 'runtime\supervisor-host.cs'
  $target=Get-WidgetSupervisorHostPath $AgentDir
  $stampFile=Join-Path $AgentDir 'supervisor-host-build.json'
  $sourceHash=Get-WidgetFileHash $source
  $stamp=Read-WidgetUpdateJson $stampFile
  # Leave a running, unchanged stable host in place during update recovery.
  if($stamp -and $stamp.sourceHash-eq $sourceHash -and [IO.File]::Exists($target) -and $stamp.binaryHash-eq (Get-WidgetFileHash $target)){return}
  $null=[IO.Directory]::CreateDirectory($AgentDir)
  $temp=Join-Path $AgentDir ('supervisor-host.'+[Guid]::NewGuid().ToString('N')+'.exe')
  $compiler=New-Object Microsoft.CSharp.CSharpCodeProvider
  try{
    # CodeDOM takes literal paths; Add-Type resolves brackets as wildcards.
    $options=New-Object CodeDom.Compiler.CompilerParameters
    $options.GenerateExecutable=$true;$options.OutputAssembly=$temp
    $options.CompilerOptions='/target:winexe /optimize+'
    $options.TempFiles=New-Object CodeDom.Compiler.TempFileCollection($AgentDir,$false)
    $null=$options.ReferencedAssemblies.Add('System.dll')
    $result=$compiler.CompileAssemblyFromSource($options,[IO.File]::ReadAllText($source,[Text.Encoding]::UTF8))
    if($result.Errors.HasErrors){throw ('Windowless host compilation failed: '+(($result.Errors|Where-Object{!$_.IsWarning}|ForEach-Object{$_.ToString()}) -join '; '))}
    if([IO.File]::Exists($target)){[IO.File]::Replace($temp,$target,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temp,$target)}
    Write-WidgetSupervisorJson $stampFile @{sourceHash=$sourceHash;binaryHash=(Get-WidgetFileHash $target)}
  }finally{$compiler.Dispose();if($options){$options.TempFiles.Delete()};if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Install-WidgetUpdateAgent([string]$AppDir,[string]$DataDir) {
  $agentDir=Get-WidgetUpdateAgentDir
  Assert-WidgetUpdateChildPath $AppDir (Split-Path $AppDir -Parent)
  $old=Read-WidgetUpdateJson (Join-Path $agentDir 'binding.json')
  if($old -and $old.appDir-ine $AppDir -and (Test-Path -LiteralPath $old.appDir)){throw 'Stable launcher belongs to an existing installation.'}
  $null=New-Item -ItemType Directory -Path $agentDir -Force
  Install-WidgetSupervisorHost $AppDir $agentDir
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
