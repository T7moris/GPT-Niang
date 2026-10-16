Option Explicit
Dim shell, fso, root, command, result
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
command = """" & shell.ExpandEnvironmentStrings("%WINDIR%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & root & "\update-agent.ps1"" -Supervisor"
On Error Resume Next
result = shell.Run(command, 0, True)
If Err.Number <> 0 Then
  Dim failure, diagnostic
  failure = CStr(Err.Number) & ": " & Err.Description
  Err.Clear
  Set diagnostic = fso.OpenTextFile(root & "\supervisor-launch-error.txt", 2, True, -1)
  diagnostic.WriteLine failure
  diagnostic.Close
  WScript.Quit 1
End If
On Error GoTo 0
WScript.Quit result
