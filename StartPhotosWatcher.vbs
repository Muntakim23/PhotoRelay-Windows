
Option Explicit

Dim shell, fso, currentFolder, ps1Path
Dim psExe, pwshPath, command

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' Find the folder containing this VBS file.
currentFolder = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path = fso.BuildPath(currentFolder, "WatchAndUpload.ps1")

' Stop quietly if the main script is missing.
If Not fso.FileExists(ps1Path) Then
    WScript.Quit 1
End If

' Prefer PowerShell 7 if installed in its standard location.
pwshPath = shell.ExpandEnvironmentStrings( _
    "%ProgramFiles%\PowerShell\7\pwsh.exe")

If fso.FileExists(pwshPath) Then
    psExe = """" & pwshPath & """"
Else
    psExe = "powershell.exe"
End If

' Execute the script without showing a console window.
command = psExe & _
    " -NoLogo -NoProfile -NonInteractive" & _
    " -ExecutionPolicy Bypass -WindowStyle Hidden" & _
    " -File """ & ps1Path & """"

shell.Run command, 0, False

Set fso = Nothing
Set shell = Nothing
