param([switch]$WidgetOnly,[switch]$SettingsMenuOnly,[string]$PreviewDirectory)
$ErrorActionPreference='Stop'
if($SettingsMenuOnly){
  $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'settings-menu.test.ps1'),[Text.Encoding]::UTF8)
  & ([ScriptBlock]::Create($source)) -TestRoot $PSScriptRoot
  return
}
if($WidgetOnly){
  $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'widget.test.ps1'),[Text.Encoding]::UTF8)
  & ([ScriptBlock]::Create($source)) -TestRoot $PSScriptRoot -PreviewDirectory $PreviewDirectory
  return
}
$powerShell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach($name in @('installation.test.ps1','update.test.ps1','lifecycle.test.ps1','entrypoint.test.ps1','quote-layout.test.ps1','vector-text.test.ps1','size.test.ps1','display.test.ps1','desktop-mode.test.ps1','drag-sizing.test.ps1','settings-menu.test.ps1','host-ready.test.ps1')){
  if($name-eq 'settings-menu.test.ps1'){& $powerShell -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath -SettingsMenuOnly}
  else {& $powerShell -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $name)}
  if($LASTEXITCODE-ne 0){throw "$name failed ($LASTEXITCODE)"}
}
$widgetTestArgs=@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-WidgetOnly')
if($PreviewDirectory){$widgetTestArgs+=@('-PreviewDirectory',$PreviewDirectory)}
& $powerShell @widgetTestArgs
if($LASTEXITCODE-ne 0){throw "Widget tests failed ($LASTEXITCODE)"}
