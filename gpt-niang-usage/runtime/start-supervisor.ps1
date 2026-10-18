$ErrorActionPreference='Stop'
$appDir=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'supervisor-task.ps1')
try{
  $info=Get-WidgetSupervisorInfo $appDir
  $installed=Get-WidgetSupervisorTask $info
  if($installed){Start-WidgetSupervisorTask $appDir}else{Register-WidgetSupervisorTask $appDir|Out-Null}
  # A successful scheduler request does not prove that Windows could open its
  # working directory or script. Confirm the actual supervisor before returning.
  Wait-WidgetSupervisorReady -Info $info -TimeoutSeconds 20 | Out-Null
  [IO.File]::WriteAllText((Join-Path $info.DataDir 'refresh.flag'),([DateTime]::UtcNow.ToString('o')+' '+[Guid]::NewGuid().ToString('N')))
  Remove-Item -LiteralPath (Join-Path $info.DataDir 'supervisor-start-error.txt') -ErrorAction SilentlyContinue
}catch{
  try{$configuration=Get-Content -LiteralPath (Join-Path $appDir 'installation.json') -Raw -Encoding UTF8|ConvertFrom-Json;[IO.File]::WriteAllText((Join-Path $configuration.dataDir 'supervisor-start-error.txt'),$_.Exception.ToString())}catch{}
  throw
}
