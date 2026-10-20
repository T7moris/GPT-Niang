Option Explicit
Dim widgetShell, widgetFiles, widgetRoot, widgetCommand
Set widgetShell = CreateObject("WScript.Shell")
Set widgetFiles = CreateObject("Scripting.FileSystemObject")
widgetRoot = widgetFiles.GetParentFolderName(WScript.ScriptFullName)
widgetCommand = """" & widgetShell.ExpandEnvironmentStrings("%WINDIR%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & widgetRoot & "\runtime\start-supervisor.ps1"""
widgetShell.Run widgetCommand, 0, False
