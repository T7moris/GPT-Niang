Option Explicit
Dim shell, fso, root, command, result
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
command = """" & shell.ExpandEnvironmentStrings("%WINDIR%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & root & "\update-agent.ps1"""
result = shell.Run(command, 0, True)
If result <> 0 Then
    shell.Popup "GPT Niang could not start. Details: " & root & "\update-diagnostic.txt", 0, "GPT Niang", 16
End If
WScript.Quit result
