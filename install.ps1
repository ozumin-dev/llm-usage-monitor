[CmdletBinding()]
param(
    [switch]$NoLaunch,
    [switch]$NoStartup,
    [switch]$SkipClaudeConfiguration
)

$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:LOCALAPPDATA 'LLMUsageMonitor'
$sourceDir = Join-Path $PSScriptRoot 'src'
$startupPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\LLM Usage Monitor.lnk'
$monitorShortcutPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\LLM Usage Monitor.lnk'
$settingsShortcutPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\LLM Usage Monitor Settings.lnk'
$statePath = Join-Path $installDir 'install-state.json'

# Stop the previous monitor before replacing its scripts. This is deliberately
# scoped to a PowerShell process whose command line contains our installed app.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
        $_.CommandLine -notmatch '(?i)\s-(Command|EncodedCommand)\s' -and
        $_.CommandLine -match '(?i)-File\s+"?[^"\r\n]*\\LLMUsageMonitor\\LLMUsageMonitor\.ps1'
    } |
    ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null }

Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -in @('python.exe', 'pythonw.exe') -and
        $_.CommandLine -match '(?i)LLMUsageMonitor[\\/]usage_api\.py'
    } |
    ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null }

New-Item -ItemType Directory -Force -Path $installDir | Out-Null
Copy-Item -LiteralPath (Join-Path $sourceDir 'UsageData.ps1') -Destination $installDir -Force
Copy-Item -LiteralPath (Join-Path $sourceDir 'LLMUsageMonitor.ps1') -Destination $installDir -Force
Copy-Item -LiteralPath (Join-Path $sourceDir 'claude-statusline.ps1') -Destination $installDir -Force
Copy-Item -LiteralPath (Join-Path $sourceDir 'claude-desktop-usage.py') -Destination $installDir -Force
Copy-Item -LiteralPath (Join-Path $sourceDir 'TrayIcon.ps1') -Destination $installDir -Force
Copy-Item -LiteralPath (Join-Path $sourceDir 'usage_api.py') -Destination $installDir -Force
Copy-Item -LiteralPath (Join-Path $sourceDir 'Settings.ps1') -Destination $installDir -Force
Copy-Item -LiteralPath (Join-Path $sourceDir 'SettingsDialog.ps1') -Destination $installDir -Force
Copy-Item -LiteralPath (Join-Path $sourceDir 'LLMUsageSettings.ps1') -Destination $installDir -Force
Copy-Item -LiteralPath (Join-Path $sourceDir 'LaunchMonitor.vbs') -Destination $installDir -Force
Copy-Item -LiteralPath (Join-Path $sourceDir 'CustomTrayIcon.example.ps1') -Destination $installDir -Force
New-Item -ItemType Directory -Force -Path (Join-Path $installDir 'icons') | Out-Null

$state = [ordered]@{ configured_claude = $false; previous_status_line = $null }
if (Test-Path -LiteralPath $statePath) {
    try { $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json } catch {}
}

if (-not $SkipClaudeConfiguration) {
    $claudeDir = Join-Path $HOME '.claude'
    $settingsPath = Join-Path $claudeDir 'settings.json'
    New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
    $settings = if (Test-Path -LiteralPath $settingsPath) {
        Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
    } else {
        New-Object psobject
    }

    if (-not $state.configured_claude) {
        $existing = $settings.PSObject.Properties['statusLine']
        if ($null -ne $existing) { $state.previous_status_line = $existing.Value }
    }

    $hookPath = Join-Path $installDir 'claude-statusline.ps1'
    $statusLine = [pscustomobject]@{
        type = 'command'
        command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $hookPath
        padding = 1
        refreshInterval = 60
    }
    $settings | Add-Member -NotePropertyName statusLine -NotePropertyValue $statusLine -Force
    $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    $state.configured_claude = $true
}

$state | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -Encoding UTF8

if (-not $NoStartup) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($startupPath)
    $shortcut.TargetPath = (Get-Command wscript.exe).Source
    $shortcut.Arguments = '"{0}"' -f (Join-Path $installDir 'LaunchMonitor.vbs')
    $shortcut.WorkingDirectory = $installDir
    $shortcut.Description = 'LLM Usage Monitor'
    $shortcut.Save()
}

$shell = New-Object -ComObject WScript.Shell
$monitorShortcut = $shell.CreateShortcut($monitorShortcutPath)
$monitorShortcut.TargetPath = (Get-Command wscript.exe).Source
$monitorShortcut.Arguments = '"{0}"' -f (Join-Path $installDir 'LaunchMonitor.vbs')
$monitorShortcut.WorkingDirectory = $installDir
$monitorShortcut.WindowStyle = 7
$monitorShortcut.Description = 'Start LLM Usage Monitor'
$monitorShortcut.Save()

$settingsShortcut = $shell.CreateShortcut($settingsShortcutPath)
$settingsShortcut.TargetPath = (Get-Command powershell.exe).Source
$settingsShortcut.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $installDir 'LLMUsageSettings.ps1')
$settingsShortcut.WorkingDirectory = $installDir
$settingsShortcut.Description = 'Configure LLM Usage Monitor'
$settingsShortcut.Save()

if (-not $NoLaunch) {
    Start-Process wscript.exe -WindowStyle Hidden -ArgumentList ('"{0}"' -f (Join-Path $installDir 'LaunchMonitor.vbs'))
}

Write-Host 'LLM Usage Monitor をインストールしました。'
Write-Host ('インストール先: {0}' -f $installDir)
if (-not $SkipClaudeConfiguration) {
    Write-Host 'Claude Desktop Code の利用状況は既定で5分ごとに更新されます。'
}
