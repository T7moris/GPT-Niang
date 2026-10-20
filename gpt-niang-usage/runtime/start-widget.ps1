param(
  [string]$WidgetPath=(Join-Path (Split-Path $PSScriptRoot -Parent) 'widget.ps1'),
  [switch]$CheckOnly,
  [switch]$Preview
)
$ErrorActionPreference='Stop'
$widgetFile=[IO.Path]::GetFullPath($WidgetPath)
$source=[IO.File]::ReadAllText($widgetFile,[Text.Encoding]::UTF8)
& ([scriptblock]::Create($source)) -AppDir ([IO.Path]::GetDirectoryName($widgetFile)) -CheckOnly:$CheckOnly -Preview:$Preview
