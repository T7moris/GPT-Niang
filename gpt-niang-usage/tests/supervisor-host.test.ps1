$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
. (Join-Path $source 'runtime\supervisor-task.ps1')
. (Join-Path $source 'runtime\update-common.ps1')
$root=Join-Path (Split-Path $source -Parent) ('docs\plan\host-test-'+[Guid]::NewGuid().ToString('N')+' [space]')
$null=[IO.Directory]::CreateDirectory($root)
$process=$null
function Assert([bool]$Value,[string]$Name){if(!$Value){throw $Name}}
function Start-HostFixture([string]$Arguments){
  $start=New-Object Diagnostics.ProcessStartInfo
  $start.FileName=Get-WidgetSupervisorHostPath $root
  $start.Arguments=$Arguments
  $start.UseShellExecute=$false;$start.CreateNoWindow=$true
  return [Diagnostics.Process]::Start($start)
}
try{
  Install-WidgetSupervisorHost $source $root
  $exe=Get-WidgetSupervisorHostPath $root
  # Verify the PE subsystem independently of the launcher's source code.
  $bytes=[IO.File]::ReadAllBytes($exe)
  $pe=[BitConverter]::ToInt32($bytes,0x3c)
  Assert ([BitConverter]::ToUInt16($bytes,$pe+24+68)-eq 2) 'Host is a console executable'
  $script=@'
param([switch]$Supervisor)
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class ConsoleProbe{[DllImport("kernel32.dll")]public static extern IntPtr GetConsoleWindow();}'
@{pid=$PID;supervisor=[bool]$Supervisor;console=[ConsoleProbe]::GetConsoleWindow().ToInt64()}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $PSScriptRoot 'probe.json') -Encoding UTF8
while(!(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'stop.flag'))){Start-Sleep -Milliseconds 50}
[Console]::Out.WriteLine(('o'*131072))
[Console]::Error.WriteLine(('e'*131072)+' expected supervisor failure')
exit 23
'@
  [IO.File]::WriteAllText((Join-Path $root 'update-agent.ps1'),$script,[Text.UTF8Encoding]::new($false))
  $process=Start-HostFixture '-Supervisor'
  $deadline=[DateTime]::UtcNow.AddSeconds(15)
  $probeFile=Join-Path $root 'probe.json'
  while(!(Test-Path -LiteralPath $probeFile) -and !$process.HasExited -and [DateTime]::UtcNow-lt $deadline){Start-Sleep -Milliseconds 50}
  if(!(Test-Path -LiteralPath $probeFile)){
    $diagnostic=Join-Path $root 'supervisor-launch-error.txt'
    if(Test-Path -LiteralPath $diagnostic){throw (Get-Content -LiteralPath $diagnostic -Raw)}
    throw 'Child did not start'
  }
  $probe=Get-Content -LiteralPath $probeFile -Raw -Encoding UTF8|ConvertFrom-Json
  Assert ($probe.supervisor -and $probe.console-eq 0) ('Child has a console window: '+($probe|ConvertTo-Json -Compress))
  Assert (!$process.HasExited) 'Host detached instead of supervising its child'
  # A no-op reinstall must work even while the stable host is running.
  $written=(Get-Item -LiteralPath $exe).LastWriteTimeUtc
  Install-WidgetSupervisorHost $source $root
  Assert ((Get-Item -LiteralPath $exe).LastWriteTimeUtc-eq $written) 'Unchanged running host was replaced'
  [IO.File]::WriteAllText((Join-Path $root 'stop.flag'),'stop')
  Assert ($process.WaitForExit(10000)) 'Host did not finish with its child'
  Assert ($process.ExitCode-eq 23) 'Child failure was not propagated to Task Scheduler'
  $diagnostic=Get-Content -LiteralPath (Join-Path $root 'supervisor-launch-error.txt') -Raw -Encoding UTF8
  Assert ($diagnostic.Length-lt 17000 -and $diagnostic.Contains('expected supervisor failure')) 'Failure output was lost or unbounded'
  $process.Dispose();$process=$null
  $process=Start-HostFixture '-Supervisor -File C:\foreign.ps1'
  Assert ($process.WaitForExit(5000) -and $process.ExitCode-eq 64) 'Unexpected arguments were accepted'
  $process.Dispose();$process=$null
  Remove-Item -LiteralPath (Join-Path $root 'update-agent.ps1')
  $process=Start-HostFixture '-Supervisor'
  Assert ($process.WaitForExit(5000) -and $process.ExitCode-eq 1) 'Missing agent did not fail'
  Assert (Test-Path -LiteralPath (Join-Path $root 'supervisor-launch-error.txt')) 'Launch failure has no diagnostic'
  Write-Output 'PASS: real Windows GUI host, windowless child, wait/exit propagation, bounded output, live reinstall and launch failures'
}finally{
  [IO.File]::WriteAllText((Join-Path $root 'stop.flag'),'stop')
  if($process){if(!$process.WaitForExit(10000)){$process.Kill()};$process.Dispose()}
  $base=[IO.Path]::GetFullPath((Join-Path (Split-Path $source -Parent) 'docs\plan')).TrimEnd('\')+'\'
  if(![IO.Path]::GetFullPath($root).StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup'}
  Remove-Item -LiteralPath $root -Recurse -Force
}
