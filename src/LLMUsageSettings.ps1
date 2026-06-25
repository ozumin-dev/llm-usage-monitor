$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'Settings.ps1')
. (Join-Path $PSScriptRoot 'SettingsDialog.ps1')

$monitorScript = Join-Path $PSScriptRoot 'LLMUsageMonitor.ps1'
if (Show-MonitorSettingsDialog -MonitorScript $monitorScript) {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -notmatch '(?i)\s-(Command|EncodedCommand)\s' -and
            $_.CommandLine -match '(?i)-File\s+"?[^"\r\n]*\\LLMUsageMonitor\\LLMUsageMonitor\.ps1'
        } |
        ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null }
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('python.exe', 'pythonw.exe') -and $_.CommandLine -match '(?i)LLMUsageMonitor[\\/]usage_api\.py' } |
        ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null }
    Start-Sleep -Milliseconds 300
    Start-Process wscript.exe -WindowStyle Hidden -ArgumentList ('"{0}"' -f (Join-Path $PSScriptRoot 'LaunchMonitor.vbs'))
}
