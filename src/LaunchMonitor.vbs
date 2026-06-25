Option Explicit

Dim shell, fileSystem, installDirectory, monitorScript, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

installDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
monitorScript = fileSystem.BuildPath(installDirectory, "LLMUsageMonitor.ps1")
command = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & monitorScript & """"

shell.Run command, 0, False
