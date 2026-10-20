Option Explicit
Dim supervisorShell, supervisorFiles, supervisorRoot, supervisorCommand, supervisorExit
Set supervisorShell = CreateObject("WScript.Shell")
Set supervisorFiles = CreateObject("Scripting.FileSystemObject")
supervisorRoot = supervisorFiles.GetParentFolderName(WScript.ScriptFullName)
supervisorCommand = """" & supervisorShell.ExpandEnvironmentStrings("%WINDIR%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & supervisorRoot & "\runtime\supervisor.ps1"""
supervisorExit = supervisorShell.Run(supervisorCommand, 0, True)
WScript.Quit supervisorExit
