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
    # Codex used to be fetched on the local refresh tick (never faster than 60s).
    $codexRefresh = [int](Get-SettingProperty $data 'codex_refresh_seconds' ([Math]::Max(60, $refresh)))
    $antigravityRefresh = [int](Get-SettingProperty $data 'antigravity_refresh_seconds' 300)
    $port = [int](Get-SettingProperty $data 'api_port' 47831)
    return [pscustomobject]@{
        CodexEnabled = [bool](Get-SettingProperty $data 'codex_enabled' $true)
        ClaudeEnabled = [bool](Get-SettingProperty $data 'claude_enabled' $true)
        AntigravityEnabled = [bool](Get-SettingProperty $data 'antigravity_enabled' $true)
        ShowCodexTrayIcon = [bool](Get-SettingProperty $data 'show_codex_tray_icon' $true)
        ShowClaudeTrayIcon = [bool](Get-SettingProperty $data 'show_claude_tray_icon' $true)
        ShowAntigravityTrayIcon = [bool](Get-SettingProperty $data 'show_antigravity_tray_icon' $true)
        # Only how often the window re-reads the fetched files; not shown in the dialog.
        LocalRefreshSeconds = [Math]::Max(5, [Math]::Min(3600, $refresh))
        CodexRefreshSeconds = [Math]::Max(60, [Math]::Min(3600, $codexRefresh))
        # The Claude usage endpoint answers HTTP 429 when polled much faster than this.
        ClaudeRefreshSeconds = [Math]::Max(30, [Math]::Min(3600, $claudeRefresh))
        AntigravityRefreshSeconds = [Math]::Max(60, [Math]::Min(3600, $antigravityRefresh))
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
    # Settings added later are read with defaults so older callers still save.
    $result = [ordered]@{
        schema_version = 1
        codex_enabled = [bool](Get-SettingProperty $Settings 'CodexEnabled' $true)
        claude_enabled = [bool](Get-SettingProperty $Settings 'ClaudeEnabled' $true)
        antigravity_enabled = [bool](Get-SettingProperty $Settings 'AntigravityEnabled' $true)
        show_codex_tray_icon = [bool]$Settings.ShowCodexTrayIcon
        show_claude_tray_icon = [bool]$Settings.ShowClaudeTrayIcon
        show_antigravity_tray_icon = [bool](Get-SettingProperty $Settings 'ShowAntigravityTrayIcon' $true)
        local_refresh_seconds = [Math]::Max(5, [Math]::Min(3600, [int](Get-SettingProperty $Settings 'LocalRefreshSeconds' 30)))
        codex_refresh_seconds = [Math]::Max(60, [Math]::Min(3600, [int](Get-SettingProperty $Settings 'CodexRefreshSeconds' 60)))
        claude_refresh_seconds = [Math]::Max(30, [Math]::Min(3600, [int]$Settings.ClaudeRefreshSeconds))
        antigravity_refresh_seconds = [Math]::Max(60, [Math]::Min(3600, [int](Get-SettingProperty $Settings 'AntigravityRefreshSeconds' 300)))
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
        $launcher = Join-Path (Split-Path -Parent $MonitorScript) 'LaunchMonitor.vbs'
        $shortcut.TargetPath = (Get-Command wscript.exe).Source
        $shortcut.Arguments = '"{0}"' -f $launcher
        $shortcut.WorkingDirectory = Split-Path -Parent $MonitorScript
        $shortcut.Description = 'LLM Usage Monitor'
        $shortcut.Save()
    } elseif (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force
    }
}
