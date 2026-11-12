# Compatibility entry for existing WPF shortcuts through update-agent.ps1.
# Delegate to the bound JS launcher instead of recreating a legacy supervisor.
$ErrorActionPreference = 'Stop'
$appDir = Split-Path $PSScriptRoot -Parent
function Same-LauncherPath([string]$Left, [string]$Right) {
  return $Left -and $Right -and [IO.Path]::IsPathRooted($Left) -and [IO.Path]::IsPathRooted($Right) -and
    [string]::Equals([IO.Path]::GetFullPath($Left), [IO.Path]::GetFullPath($Right), [StringComparison]::OrdinalIgnoreCase)
}
$config = Get-Content -LiteralPath (Join-Path $appDir 'installation.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$package = Get-Content -LiteralPath (Join-Path $appDir 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if ($package.name -ne 'gpt-niang-usage' -or $package.architecture -ne 'javascript-electron' -or
    $config.architecture -ne 'javascript-electron' -or $config.candidate -or
    $config.version -ne $package.version -or $config.sid -ne $sid -or
    !(Same-LauncherPath $config.appDir $appDir) -or ![IO.Path]::IsPathRooted($config.dataDir)) {
  throw 'Legacy shortcut does not belong to this installed GPT Niang.'
}
$launcher = Join-Path $config.dataDir 'launcher\GPTNiang.Start.exe'
if (!(Same-LauncherPath $config.launcherPath $launcher) -or !(Test-Path -LiteralPath $launcher -PathType Leaf)) {
  throw 'GPT Niang launcher is missing or its location does not match the installation.'
}
$binding = Get-Content -LiteralPath (Join-Path (Split-Path $launcher -Parent) 'launcher.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($binding.sid -ne $sid -or !(Same-LauncherPath $binding.appDir $appDir) -or
    !(Same-LauncherPath $binding.dataDir $config.dataDir)) {
  throw 'GPT Niang launcher binding does not match the installation.'
}
$child = Start-Process -FilePath $launcher -WorkingDirectory (Split-Path $launcher -Parent) -WindowStyle Hidden -PassThru
$child.WaitForExit()
if ($child.ExitCode -ne 0) { throw ('GPT Niang launcher failed with exit code ' + $child.ExitCode) }
