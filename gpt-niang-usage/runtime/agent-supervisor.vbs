Option Explicit
Dim shell, fso, root, command, result
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
command = """" & shell.ExpandEnvironmentStrings("%WINDIR%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & root & "\update-agent.ps1"" -Supervisor"
Do
    On Error Resume Next
    result = shell.Run(command, 0, True)
    If Err.Number <> 0 Then
        result = 1
        Err.Clear
    End If
    On Error GoTo 0
    If result = 0 Then Exit Do
    WScript.Sleep 5000
Loop
WScript.Quit result
