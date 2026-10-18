function Test-WidgetWritableDirectory([string]$Directory) {
  $existing=$Directory
  while(!(Test-Path -LiteralPath $existing)){$existing=Split-Path $existing -Parent;if(!$existing){throw 'Writable parent directory unavailable.'}}
  $probe=Join-Path $existing ('.gpt-niang-write-'+[Guid]::NewGuid().ToString('N'))
  try{$stream=[IO.File]::Open($probe,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$stream.Dispose()}
  finally{if([IO.File]::Exists($probe)){[IO.File]::Delete($probe)}}
}
function Assert-WidgetNoReparsePoint([string]$Directory) {
  for($current=[IO.Path]::GetFullPath($Directory);$current;$current=Split-Path $current -Parent){
    if((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes-band [IO.FileAttributes]::ReparsePoint)){throw 'Installation or update paths may not contain links.'}
  }
}
function Get-WidgetInstallPreflight {
  param([Parameter(Mandatory=$true)][string]$SourceDir,[Parameter(Mandatory=$true)][string]$AppDir)
  $appDir=[IO.Path]::GetFullPath($AppDir).TrimEnd('\');$sourceDir=[IO.Path]::GetFullPath($SourceDir).TrimEnd('\')
  $programRoot=Split-Path $appDir -Parent;$agentDir=[IO.Path]::GetFullPath((Get-WidgetUpdateAgentDir)).TrimEnd('\')
  if($agentDir-ieq $programRoot -or $agentDir.StartsWith($programRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or $programRoot.StartsWith($agentDir+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Stable update launcher must be outside the program directory.'}
  $localData=[Environment]::GetFolderPath('LocalApplicationData')
  if(!$localData){throw 'Local application data folder unavailable.'}
  $dataDir=Join-Path (Get-WidgetStorageRoot) 'state'
  $previousConfig=Join-Path $appDir 'installation.json'
  if(Test-Path -LiteralPath $previousConfig){$previous=Read-WidgetUpdateJson $previousConfig;$dataDir=Get-WidgetInstallationDataDir -AppDir $appDir -Configuration $previous}
  $dataDir=[IO.Path]::GetFullPath($dataDir).TrimEnd('\')
  if($appDir-ieq $dataDir -or $appDir.StartsWith($dataDir+'\',[StringComparison]::OrdinalIgnoreCase) -or $dataDir.StartsWith((Join-Path $appDir 'runtime')+'\',[StringComparison]::OrdinalIgnoreCase) -or $dataDir-ieq (Join-Path $appDir 'runtime')){throw 'Data directory overlaps program files.'}
  $nodeCommand=Get-Command node.exe -ErrorAction SilentlyContinue
  if(!$nodeCommand){throw 'Node.js 20 or later is required. Install Node.js and reopen the installer.'}
  $node=$nodeCommand.Source
  $nodeMajor=[int]((& $node --version).TrimStart('v').Split('.')[0])
  if($nodeMajor-lt 20){throw 'Node.js 20 or later is required.'}
  $codexCommand=Get-Command codex.exe -ErrorAction SilentlyContinue
  $codex=if($codexCommand){$codexCommand.Source}else{$null}
  if(!$codex){
    $bundled=Join-Path $localData 'OpenAI\Codex\bin'
    if(Test-Path -LiteralPath $bundled){$codex=(Get-ChildItem -LiteralPath $bundled -Filter codex.exe -File -Recurse|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1).FullName}
  }
  if(!$codex){throw 'Codex executable unavailable. Install and open the Codex desktop app first.'}
  $required=Read-WidgetUpdateJson (Join-Path $sourceDir 'runtime\install-files.json')
  if(!$required){throw 'Missing installation file list.'}
  foreach($file in $required){if(!(Test-Path -LiteralPath (Join-Path $sourceDir $file) -PathType Leaf)){throw ('Missing file: '+$file.Replace('/','\'))}}
  foreach($path in @($appDir,$sourceDir,$dataDir,(Get-WidgetUpdateAgentDir))){Assert-WidgetNoReparsePoint $path}
  $manifest=Read-WidgetUpdateJson (Join-Path $sourceDir '.codex-plugin\plugin.json')
  $package=Read-WidgetUpdateJson (Join-Path $sourceDir 'package.json')
  if(!$manifest.version -or $manifest.version-ne $package.version -or $manifest.version-notmatch '^\d+\.\d+\.\d+$'){throw 'Package version mismatch.'}
  if(!(Test-Path -LiteralPath (Join-Path (Split-Path $sourceDir -Parent) '.agents\plugins\marketplace.json'))){throw 'Marketplace metadata missing.'}
  $startup=[Environment]::GetFolderPath('Startup');if(!$startup){throw 'Windows Startup folder unavailable.'}
  $shortcut=Join-Path $startup 'GPT Niang Usage.lnk'
  $config=@{version=$manifest.version;appDir=$appDir;dataDir=$dataDir;nodePath=$node;codexPath=$codex;marketplaceRoot=(Split-Path $appDir -Parent);startupShortcut=$shortcut;installedAt=[DateTime]::UtcNow.ToString('o');updateAgent=(Get-WidgetUpdateAgentDir);updaterSchema=1}
  $info=Get-WidgetSupervisorInfo -AppDir $appDir -Configuration $config
  $null=Get-WidgetSupervisorTask $info
  if(Test-Path -LiteralPath $shortcut){
    $existing=(New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
    if(!(Test-WidgetStartupShortcutIdentity -Shortcut $existing -AppDir $appDir)){throw 'Existing shortcut belongs to another installation.'}
  }
  $binding=Read-WidgetUpdateJson (Join-Path (Get-WidgetUpdateAgentDir) 'binding.json')
  if($binding -and $binding.appDir-ine $appDir -and (Test-Path -LiteralPath $binding.appDir)){throw 'Stable launcher belongs to another installation.'}
  foreach($directory in @($appDir,(Split-Path (Split-Path $appDir -Parent) -Parent),$dataDir,$startup,(Get-WidgetUpdateAgentDir))){Test-WidgetWritableDirectory $directory}
  return $config
}
function Assert-WidgetPluginRegistration([string]$Codex,[string]$Version) {
  $processInfo=New-Object System.Diagnostics.ProcessStartInfo
  $processInfo.FileName=$Codex;$processInfo.Arguments='plugin list --json';$processInfo.UseShellExecute=$false
  $processInfo.RedirectStandardOutput=$true;$processInfo.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
  $process=New-Object System.Diagnostics.Process;$process.StartInfo=$processInfo
  try{
    if(!$process.Start()){throw 'Cannot start Codex plugin list.'}
    $pending=$process.StandardOutput.ReadToEndAsync()
    if(!$process.WaitForExit(30000)){$process.Kill();throw 'Plugin verification timed out.'}
    if($process.ExitCode-ne 0){throw 'Cannot verify plugin registration.'}
    $catalog=$pending.Result|ConvertFrom-Json
  }finally{$process.Dispose()}
  $match=@($catalog.installed|Where-Object{$_.pluginId-eq 'gpt-niang-usage@gpt-niang-local' -and $_.version-eq $Version -and $_.installed -and $_.enabled})
  if($match.Count-ne 1){throw 'Codex did not report one enabled GPT Niang plugin.'}
}
