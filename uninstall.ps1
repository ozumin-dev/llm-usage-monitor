[CmdletBinding()]
param([switch]$KeepClaudeConfiguration)

$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:LOCALAPPDATA 'LLMUsageMonitor'
$statePath = Join-Path $installDir 'install-state.json'
$startupPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\LLM Usage Monitor.lnk'
$monitorShortcutPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\LLM Usage Monitor.lnk'
$settingsShortcutPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\LLM Usage Monitor Settings.lnk'

if (Test-Path -LiteralPath $startupPath) { Remove-Item -LiteralPath $startupPath -Force }
if (Test-Path -LiteralPath $monitorShortcutPath) { Remove-Item -LiteralPath $monitorShortcutPath -Force }
if (Test-Path -LiteralPath $settingsShortcutPath) { Remove-Item -LiteralPath $settingsShortcutPath -Force }

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
        $_.CommandLine -notmatch '(?i)\s-(Command|EncodedCommand)\s' -and
        $_.CommandLine -match '(?i)-File\s+"?[^"\r\n]*\\LLMUsageMonitor\\LLMUsageMonitor\.ps1'
    } |
    ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null }
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in @('python.exe', 'pythonw.exe') -and $_.CommandLine -match '(?i)LLMUsageMonitor[\\/]usage_api\.py' } |
    ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null }

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
