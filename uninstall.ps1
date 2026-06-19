[CmdletBinding()]
param([switch]$KeepClaudeConfiguration)

$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:LOCALAPPDATA 'LLMUsageMonitor'
$statePath = Join-Path $installDir 'install-state.json'
$startupPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\LLM Usage Monitor.lnk'

if (Test-Path -LiteralPath $startupPath) { Remove-Item -LiteralPath $startupPath -Force }

if (-not $KeepClaudeConfiguration -and (Test-Path -LiteralPath $statePath)) {
    try {
        $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        $settingsPath = Join-Path $HOME '.claude\settings.json'
        if ($state.configured_claude -and (Test-Path -LiteralPath $settingsPath)) {
            $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
            $currentCommand = if ($settings.statusLine) { "$($settings.statusLine.command)" } else { '' }
            if ($currentCommand -like '*LLMUsageMonitor*claude-statusline.ps1*') {
                if ($null -ne $state.previous_status_line) {
                    $settings | Add-Member -NotePropertyName statusLine -NotePropertyValue $state.previous_status_line -Force
                } else {
                    $settings.PSObject.Properties.Remove('statusLine')
                }
                $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
            }
        }
    } catch {
        Write-Warning ('Claude Code の設定復元に失敗しました: {0}' -f $_.Exception.Message)
    }
}

if (Test-Path -LiteralPath $installDir) {
    Remove-Item -LiteralPath $installDir -Recurse -Force
}
Write-Host 'LLM Usage Monitor をアンインストールしました。'
