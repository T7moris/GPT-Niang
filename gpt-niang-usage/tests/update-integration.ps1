# Optional real Codex CLI / Task Scheduler test. It uses a private Codex home,
# a dedicated task name, temporary shortcut and launcher, and never opens a GUI.
$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-update-live-'+[Guid]::NewGuid().ToString('N'))
$app=Join-Path $testRoot 'install\gpt-niang-usage';$agent=Join-Path $testRoot 'agent';$data=Join-Path $testRoot 'state'
$powerShell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$taskName='GPT Niang Usage Updater Test - '+$sid
$processes=New-Object Collections.Generic.List[Diagnostics.Process]
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
$lock=$null
function Copy-TestPackage([string]$Root,[string]$Version) {
  $null=New-Item -ItemType Directory -Path $Root -Force
  $target=Join-Path $Root 'gpt-niang-usage';Copy-Item -LiteralPath $source -Destination $target -Recurse
  $metadata=Join-Path $Root '.agents\plugins';$null=New-Item -ItemType Directory -Path $metadata -Force
  Copy-Item -LiteralPath (Join-Path (Split-Path $source -Parent) '.agents\plugins\marketplace.json') -Destination $metadata
  foreach($name in @('package.json','.codex-plugin\plugin.json')){
    $file=Join-Path $target $name;$value=Get-Content -LiteralPath $file -Raw -Encoding UTF8|ConvertFrom-Json;$value.version=$Version
    [IO.File]::WriteAllText($file,($value|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
  }
  $files=@{
    'update-common.ps1'=@{Before="Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'GPTNiangUsage\update-agent'";After=("'"+$agent.Replace("'","''")+"'")}
    'supervisor-task.ps1'=@{Before='(''GPT Niang Usage - ''+$sid)';After='(''GPT Niang Usage Updater Test - ''+$sid)'}
    'install-preflight.ps1'=@{Before="[Environment]::GetFolderPath('Startup')";After=("'"+(Join-Path $testRoot 'startup').Replace("'","''")+"'")}
    'supervisor.ps1'=@{Before='$hosts=@([GptWidgetSupervisorNative]::Hosts())';After='$hosts=@()'}
    'update-agent.ps1'=@{Before='$ErrorActionPreference=''Stop''';After=('$ErrorActionPreference=''Stop'''+[Environment]::NewLine+'$env:CODEX_HOME='''+(Join-Path $testRoot 'codex-home').Replace("'","''")+'''')}
  }
  foreach($entry in $files.GetEnumerator()) {
    $file=Join-Path $target ('runtime\'+$entry.Key);$text=[IO.File]::ReadAllText($file)
    $text=$text.Replace($entry.Value.Before,$entry.Value.After)
    if($entry.Key-eq 'supervisor.ps1'){$text=$text.Replace('Local\GPTNiangSupervisor-',('Local\GPTNiangSupervisorTest-'+(Split-Path $testRoot -Leaf)+'-'))}
    [IO.File]::WriteAllText($file,$text,[Text.UTF8Encoding]::new($false))
  }
}
function Start-IsolatedPowerShell([string]$Script,[string]$Extra='') {
  $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=$powerShell
  $info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$Script+'" '+$Extra
  $info.UseShellExecute=$false;$info.CreateNoWindow=$true
  $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
  $info.StandardOutputEncoding=[Text.Encoding]::UTF8;$info.StandardErrorEncoding=[Text.Encoding]::UTF8
  $info.EnvironmentVariables['CODEX_HOME']=Join-Path $testRoot 'codex-home'
  $process=New-Object Diagnostics.Process;$process.StartInfo=$info
  $null=$process.Start()
  $process|Add-Member OutputTask ($process.StandardOutput.ReadToEndAsync())
  $process|Add-Member ErrorTask ($process.StandardError.ReadToEndAsync())
  $processes.Add($process);return $process
}
function Compress-TestPackage([string]$Directory,[string]$Archive) {
  $zip=[IO.Compression.ZipFile]::Open($Archive,[IO.Compression.ZipArchiveMode]::Create)
  try{
    foreach($file in (Get-ChildItem -LiteralPath $Directory -Recurse -File -Force)){
      $name='bundle/'+$file.FullName.Substring($Directory.Length+1).Replace('\','/')
      $null=[IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$file.FullName,$name,[IO.Compression.CompressionLevel]::Optimal)
    }
  }finally{$zip.Dispose()}
}
function Wait-IsolatedProcess($Process,[switch]$Idle,[switch]$ExpectFailure) {
  $deadline=[DateTime]::UtcNow.AddSeconds(90)
  $diagnostics=@{}
  while(!$Process.HasExited){
    if($Idle){Write-WidgetSupervisorJson (Join-Path $data 'update-idle.json') @{at=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();pid=$PID;menu=$false;drag=$false;editor=$false}}
    if([DateTime]::UtcNow-gt $deadline){$Process.Kill();throw 'Integration process timed out.'}
    foreach($file in @((Join-Path $agent 'update-diagnostic.txt'),(Join-Path $data 'supervisor-error.txt'),(Join-Path $data 'supervisor-status.json'))){if(Test-Path -LiteralPath $file){$diagnostics[$file]=[IO.File]::ReadAllText($file)}}
    Start-Sleep -Milliseconds 500
  }
  if($ExpectFailure){if($Process.ExitCode-eq 0){throw 'Expected isolated installation failure.'};return}
  if($Process.ExitCode-ne 0){throw ('Integration process failed: '+$Process.ExitCode+[Environment]::NewLine+($diagnostics.Values -join [Environment]::NewLine)+[Environment]::NewLine+$Process.ErrorTask.Result+[Environment]::NewLine+$Process.OutputTask.Result)}
}
try {
  if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){throw 'A previous integration task exists; inspect it before rerunning.'}
  $null=New-Item -ItemType Directory -Path $data -Force
  $null=New-Item -ItemType Directory -Path (Join-Path $testRoot 'startup') -Force
  $null=New-Item -ItemType Directory -Path (Join-Path $testRoot 'codex-home') -Force
  Copy-TestPackage (Split-Path $app -Parent) '1.3.2'
  . (Join-Path $app 'runtime\supervisor-task.ps1')
  . (Join-Path $app 'runtime\update-common.ps1')
  Write-WidgetSupervisorJson (Join-Path $app 'installation.json') @{appDir=$app;dataDir=$data;version='1.3.2'}
  Write-WidgetSupervisorJson (Join-Path $data 'update-preferences.json') @{automatic=$false}
  Wait-IsolatedProcess (Start-IsolatedPowerShell (Join-Path $app 'Install.ps1'))
  $registered=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
  if($registered.Actions[0].WorkingDirectory-ine $agent){throw 'Real task did not use the isolated stable entry.'}
  Write-Output 'PASS real initial plugin and stable scheduled task registration'
  $lock=Enter-WidgetUpdateLock
  $job=Join-Path $data ('updates\'+$lock.Token);$candidate=Join-Path $job 'package\bundle'
  Copy-TestPackage $candidate '1.3.3'
  $archive=Join-Path $job 'release.zip'
  Compress-TestPackage $candidate $archive
  Write-WidgetSupervisorJson (Join-Path $agent 'update-transaction.json') @{schema=1;token=$lock.Token;phase='prepared';root=(Split-Path $app -Parent);appDir=$app;dataDir=$data;candidate=$candidate;archive=$archive;hash=(Get-WidgetFileHash $archive);version='1.3.3';oldVersion='1.3.2';mode='manual'}
  Wait-IsolatedProcess (Start-IsolatedPowerShell (Join-Path $agent 'update-helper.ps1') ('-Token '+$lock.Token)) -Idle
  $journal=Read-WidgetUpdateJson (Join-Path $agent 'update-transaction.json')
  if($journal.phase-ne 'committed'){throw ('Real upgrade did not commit: '+$journal.phase)}
  if((Read-WidgetUpdateJson (Join-Path $app 'installation.json')).version-ne '1.3.3'){throw 'Real upgraded manifest registration missing.'}
  if((Read-WidgetUpdateJson (Join-Path $data 'update-preferences.json')).automatic){throw 'Real upgrade lost disabled preference.'}
  Write-Output 'PASS real upgrade, enabled Codex plugin version, stable supervisor heartbeat and retained preference'
  Exit-WidgetUpdateLock $lock;$lock=$null

  $lock=Enter-WidgetUpdateLock
  $job=Join-Path $data ('updates\'+$lock.Token);$candidate=Join-Path $job 'package\bundle'
  Copy-TestPackage $candidate '1.3.4'
  $brokenInstaller=Join-Path $candidate 'gpt-niang-usage\Install.ps1'
  $text=[IO.File]::ReadAllText($brokenInstaller)
  $text=$text.Replace('$appDir=$PSScriptRoot',"throw 'Deliberate isolated installer failure.'"+[Environment]::NewLine+'$appDir=$PSScriptRoot')
  [IO.File]::WriteAllText($brokenInstaller,$text,[Text.UTF8Encoding]::new($false))
  $archive=Join-Path $job 'release.zip'
  Compress-TestPackage $candidate $archive
  Write-WidgetSupervisorJson (Join-Path $agent 'update-transaction.json') @{schema=1;token=$lock.Token;phase='prepared';root=(Split-Path $app -Parent);appDir=$app;dataDir=$data;candidate=$candidate;archive=$archive;hash=(Get-WidgetFileHash $archive);version='1.3.4';oldVersion='1.3.3';mode='manual'}
  Wait-IsolatedProcess (Start-IsolatedPowerShell (Join-Path $agent 'update-helper.ps1') ('-Token '+$lock.Token)) -Idle -ExpectFailure
  if((Read-WidgetUpdateJson (Join-Path $agent 'update-transaction.json')).phase-ne 'rolled-back'){throw 'Real installation failure did not restore the previous version.'}
  Write-Output 'PASS real failed installer restores and re-registers previous plugin'
  Exit-WidgetUpdateLock $lock;$lock=$null

  # Simulate power loss after the old root rename. Start the real scheduled entry,
  # which must recover before entering its supervisor loop, without killing itself.
  Stop-WidgetSupervisorTask $app
  $lock=Enter-WidgetUpdateLock;$token=$lock.Token;$root=Split-Path $app -Parent
  $job=Join-Path $data ('updates\'+$token);$candidate=Join-Path $job 'package\bundle'
  $null=New-Item -ItemType Directory -Path $candidate -Force
  Write-WidgetSupervisorJson (Join-Path $agent 'update-transaction.json') @{schema=1;token=$token;phase='moving-new';root=$root;appDir=$app;dataDir=$data;candidate=$candidate;archive=(Join-Path $job 'release.zip');version='1.3.4';oldVersion='1.3.3';mode='manual'}
  [IO.Directory]::Move($root,($root+'.backup-'+$token))
  Exit-WidgetUpdateLock $lock;$lock=$null
  Start-ScheduledTask -TaskName $taskName
  $deadline=[DateTime]::UtcNow.AddSeconds(45)
  do {
    $journal=Read-WidgetUpdateJson (Join-Path $agent 'update-transaction.json')
    $health=Read-WidgetUpdateJson (Join-Path $data 'supervisor-status.json')
    if($journal.phase-eq 'rolled-back' -and $health -and $health.taskName-eq $taskName){break}
    if($journal.phase-eq 'recovery-failed' -or [DateTime]::UtcNow-gt $deadline){
      $diagnostic=Join-Path $agent 'update-diagnostic.txt'
      $message='Real scheduled restart recovery failed: '+$journal.phase
      if(Test-Path -LiteralPath $diagnostic){$message+=[Environment]::NewLine+[IO.File]::ReadAllText($diagnostic)}
      throw $message
    }
    Start-Sleep -Milliseconds 500
  }while($true)
  Write-Output 'PASS real scheduled restart recovers the missing program directory and supervisor'
  Wait-IsolatedProcess (Start-IsolatedPowerShell (Join-Path $app 'Uninstall.ps1'))
  Write-Output 'PASS isolated plugin and task cleanup'
} catch {Write-Output $_.Exception.Message;throw} finally {
  if($lock){Exit-WidgetUpdateLock $lock}
  foreach($process in $processes){if(!$process.HasExited){$process.Kill();$process.WaitForExit()};$process.Dispose()}
  $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if($task){
    if($task.Actions[0].WorkingDirectory-ine $agent){throw 'Refusing cleanup of a foreign integration task.'}
    Stop-ScheduledTask -TaskName $taskName
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
  }
  $expected='"'+(Join-Path $agent 'update-agent.ps1')+'"'
  $children=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"|Where-Object{$_.ProcessId-ne $PID -and $_.CommandLine -and $_.CommandLine.IndexOf($expected,[StringComparison]::OrdinalIgnoreCase)-ge 0})
  foreach($child in $children){
    $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+$child.ProcessId)
    if($current -and $current.CreationDate-eq $child.CreationDate){Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue}
  }
  Start-Sleep -Milliseconds 300
  $resolved=[IO.Path]::GetFullPath($testRoot);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
  if(!$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf)-notlike 'gpt-niang-update-live-*'){throw 'Unsafe integration cleanup path.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
