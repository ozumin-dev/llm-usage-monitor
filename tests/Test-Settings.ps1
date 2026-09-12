$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\Settings.ps1')

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message (expected=$Expected, actual=$Actual)" }
}

$path = Join-Path $env:TEMP ('llm-usage-settings-test-{0}.json' -f $PID)
$legacyPath = Join-Path $env:TEMP ('llm-usage-settings-legacy-test-{0}.json' -f $PID)
try {
    $defaults = Get-MonitorSettings -Path $path
    Assert-Equal $true $defaults.ShowCodexTrayIcon 'Default Codex icon'
    Assert-Equal $true $defaults.ShowClaudeTrayIcon 'Default Claude icon'
    Assert-Equal $true $defaults.ShowAntigravityTrayIcon 'Default Antigravity icon'
    Assert-Equal 30 $defaults.LocalRefreshSeconds 'Default local refresh'
    Assert-Equal 300 $defaults.ClaudeRefreshSeconds 'Default Claude refresh'
    Assert-Equal 60 $defaults.CodexRefreshSeconds 'Default Codex refresh'
    Assert-Equal 300 $defaults.AntigravityRefreshSeconds 'Default Antigravity refresh'
    Assert-Equal $true $defaults.CodexEnabled 'Default Codex fetch'
    Assert-Equal $true $defaults.ClaudeEnabled 'Default Claude fetch'
    Assert-Equal $true $defaults.AntigravityEnabled 'Default Antigravity fetch'
    Assert-Equal $true $defaults.UsageAlertsEnabled 'Default usage alerts state'
    Assert-Equal $true $defaults.ApiEnabled 'Default API state'
    Assert-Equal 47831 $defaults.ApiPort 'Default API port'

    $changed = [pscustomobject]@{
        ShowCodexTrayIcon = $false
        ShowClaudeTrayIcon = $false
        LocalRefreshSeconds = 12
        ClaudeRefreshSeconds = 45
        UsageAlertsEnabled = $false
        ApiEnabled = $true
        ApiPort = 49001
    }
    Save-MonitorSettings -Settings $changed -Path $path
    $loaded = Get-MonitorSettings -Path $path
    Assert-Equal $false $loaded.ShowCodexTrayIcon 'Saved Codex icon'
    Assert-Equal $false $loaded.ShowClaudeTrayIcon 'Saved Claude icon'
    Assert-Equal 12 $loaded.LocalRefreshSeconds 'Saved local refresh'
    Assert-Equal 45 $loaded.ClaudeRefreshSeconds 'Saved Claude refresh'
    Assert-Equal $false $loaded.UsageAlertsEnabled 'Saved usage alerts state'
    Assert-Equal 49001 $loaded.ApiPort 'Saved API port'
    Assert-Equal $true $loaded.ShowAntigravityTrayIcon 'Antigravity icon defaults on when the caller omits it'

    $changed | Add-Member -NotePropertyName ShowAntigravityTrayIcon -NotePropertyValue $false
    Save-MonitorSettings -Settings $changed -Path $path
    Assert-Equal $false (Get-MonitorSettings -Path $path).ShowAntigravityTrayIcon 'Saved Antigravity icon'
    Assert-Equal $true (Get-MonitorSettings -Path $path).CodexEnabled 'Fetch defaults on when the caller omits it'

    $perProvider = [pscustomobject]@{
        CodexEnabled = $false; ClaudeEnabled = $true; AntigravityEnabled = $false
        ShowCodexTrayIcon = $true; ShowClaudeTrayIcon = $true; ShowAntigravityTrayIcon = $true
        CodexRefreshSeconds = 120; ClaudeRefreshSeconds = 10; AntigravityRefreshSeconds = 20
        UsageAlertsEnabled = $true; ApiEnabled = $true; ApiPort = 47831
    }
    Save-MonitorSettings -Settings $perProvider -Path $path
    $loaded = Get-MonitorSettings -Path $path
    Assert-Equal $false $loaded.CodexEnabled 'Saved Codex fetch off'
    Assert-Equal $false $loaded.AntigravityEnabled 'Saved Antigravity fetch off'
    Assert-Equal 120 $loaded.CodexRefreshSeconds 'Saved Codex refresh'
    Assert-Equal 10 $loaded.ClaudeRefreshSeconds 'Saved Claude refresh'
    Assert-Equal 20 $loaded.AntigravityRefreshSeconds 'Saved Antigravity refresh'
    Assert-Equal 30 $loaded.LocalRefreshSeconds 'Local refresh defaults when the caller omits it'

    [System.IO.File]::WriteAllText($legacyPath, '{"claude_refresh_minutes":7}', (New-Object System.Text.UTF8Encoding($false)))
    $migrated = Get-MonitorSettings -Path $legacyPath
    Assert-Equal 420 $migrated.ClaudeRefreshSeconds 'Legacy Claude refresh migration'
} finally {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    if (Test-Path -LiteralPath $legacyPath) { Remove-Item -LiteralPath $legacyPath -Force }
}

Write-Host 'All Settings tests passed.' -ForegroundColor Green
