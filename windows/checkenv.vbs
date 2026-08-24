' Sonde minimale : verifie que Windows Script Host est fonctionnel et que
' les composants dont dependent le collecteur et le plugin sont presents.
' Appelee par install.cmd, qui ne peut pas s'en assurer autrement.
Option Explicit
Dim oFSO, oDict, oRe
On Error Resume Next
Set oFSO  = CreateObject("Scripting.FileSystemObject")
If Err.Number <> 0 Then WScript.Quit 1
Set oDict = CreateObject("Scripting.Dictionary")
If Err.Number <> 0 Then WScript.Quit 1
Set oRe   = CreateObject("VBScript.RegExp")
If Err.Number <> 0 Then WScript.Quit 1
On Error GoTo 0
WScript.Quit 0
