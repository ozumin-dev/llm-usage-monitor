Set-StrictMode -Version 2.0

function Get-MonitorSettingsPath {
    return (Join-Path $env:LOCALAPPDATA 'LLMUsageMonitor\settings.json')
}

function Get-StartupShortcutPath {
    return (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\LLM Usage Monitor.lnk')
}

function Get-SettingProperty {
    param($Object, [string]$Name, $Default)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Get-MonitorSettings {
    [CmdletBinding()]
    param([string]$Path = (Get-MonitorSettingsPath))

    $data = $null
    if (Test-Path -LiteralPath $Path) {
        try { $data = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -ErrorAction Stop } catch { $data = $null }
    }

    $refresh = [int](Get-SettingProperty $data 'local_refresh_seconds' 30)
    $claudeRefreshValue = Get-SettingProperty $data 'claude_refresh_seconds' $null
    if ($null -eq $claudeRefreshValue) {
        # Migrate settings written by versions that stored this value in minutes.
        $claudeRefreshValue = [int](Get-SettingProperty $data 'claude_refresh_minutes' 5) * 60
    }
    $claudeRefresh = [int]$claudeRefreshValue
    $port = [int](Get-SettingProperty $data 'api_port' 47831)
    return [pscustomobject]@{
        ShowCodexTrayIcon = [bool](Get-SettingProperty $data 'show_codex_tray_icon' $true)
        ShowClaudeTrayIcon = [bool](Get-SettingProperty $data 'show_claude_tray_icon' $true)
        LocalRefreshSeconds = [Math]::Max(5, [Math]::Min(3600, $refresh))
        ClaudeRefreshSeconds = [Math]::Max(5, [Math]::Min(3600, $claudeRefresh))
        UsageAlertsEnabled = [bool](Get-SettingProperty $data 'usage_alerts_enabled' $true)
        ApiEnabled = [bool](Get-SettingProperty $data 'api_enabled' $true)
        ApiPort = [Math]::Max(1024, [Math]::Min(65535, $port))
    }
}

function Save-MonitorSettings {
    [CmdletBinding()]
    param(
        $Settings,
        [string]$Path = (Get-MonitorSettingsPath)
    )
    $result = [ordered]@{
        schema_version = 1
        show_codex_tray_icon = [bool]$Settings.ShowCodexTrayIcon
        show_claude_tray_icon = [bool]$Settings.ShowClaudeTrayIcon
        local_refresh_seconds = [Math]::Max(5, [Math]::Min(3600, [int]$Settings.LocalRefreshSeconds))
        claude_refresh_seconds = [Math]::Max(5, [Math]::Min(3600, [int]$Settings.ClaudeRefreshSeconds))
        usage_alerts_enabled = [bool]$Settings.UsageAlertsEnabled
        api_enabled = [bool]$Settings.ApiEnabled
        api_port = [Math]::Max(1024, [Math]::Min(65535, [int]$Settings.ApiPort))
    }
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporary = Join-Path $directory ('.settings.{0}.tmp' -f $PID)
    $json = $result | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($temporary, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Test-MonitorStartupEnabled {
    return (Test-Path -LiteralPath (Get-StartupShortcutPath))
}

function Set-MonitorStartupEnabled {
    param([bool]$Enabled, [string]$MonitorScript)
    $shortcutPath = Get-StartupShortcutPath
    if ($Enabled) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = (Get-Command powershell.exe).Source
        $shortcut.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $MonitorScript
        $shortcut.WorkingDirectory = Split-Path -Parent $MonitorScript
        $shortcut.Description = 'LLM Usage Monitor'
        $shortcut.Save()
    } elseif (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force
    }
}
