$ErrorActionPreference='Stop'
$appDir=Split-Path $PSScriptRoot -Parent
try{
  . (Join-Path $PSScriptRoot 'supervisor-task.ps1')
  $info=Get-WidgetSupervisorInfo $appDir
  $installed=Get-WidgetSupervisorTask $info
  if($installed){Start-WidgetSupervisorTask $appDir}else{Register-WidgetSupervisorTask $appDir|Out-Null}
  [IO.File]::WriteAllText((Join-Path $info.DataDir 'refresh.flag'),([DateTime]::UtcNow.ToString('o')+' '+[Guid]::NewGuid().ToString('N')))
  Remove-Item -LiteralPath (Join-Path $info.DataDir 'supervisor-start-error.txt') -ErrorAction SilentlyContinue
}catch{
  try{$configuration=Get-Content -LiteralPath (Join-Path $appDir 'installation.json') -Raw -Encoding UTF8|ConvertFrom-Json;[IO.File]::WriteAllText((Join-Path $configuration.dataDir 'supervisor-start-error.txt'),$_.Exception.ToString())}catch{}
  throw
}
