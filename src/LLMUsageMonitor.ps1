[CmdletBinding()]
param(
    [int]$RefreshSeconds = 30,
    [int]$ApiPort = 47831,
    [switch]$DisableApi,
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UsageData.ps1')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'Settings.ps1')
. (Join-Path $PSScriptRoot 'SettingsDialog.ps1')
. (Join-Path $PSScriptRoot 'TrayIcon.ps1')
$customTrayIconScript = Join-Path $PSScriptRoot 'CustomTrayIcon.ps1'
if (Test-Path -LiteralPath $customTrayIconScript) {
    try { . $customTrayIconScript } catch { Write-Warning ('CustomTrayIcon.ps1 could not be loaded: {0}' -f $_.Exception.Message) }
}
[System.Windows.Forms.Application]::EnableVisualStyles()

$monitorSettings = Get-MonitorSettings
if (-not $PSBoundParameters.ContainsKey('RefreshSeconds')) { $RefreshSeconds = $monitorSettings.LocalRefreshSeconds }
if (-not $PSBoundParameters.ContainsKey('ApiPort')) { $ApiPort = $monitorSettings.ApiPort }
if (-not $PSBoundParameters.ContainsKey('DisableApi')) { $DisableApi = -not $monitorSettings.ApiEnabled }
$showCodexTrayIcon = $monitorSettings.ShowCodexTrayIcon
$showClaudeTrayIcon = $monitorSettings.ShowClaudeTrayIcon
$showAntigravityTrayIcon = $monitorSettings.ShowAntigravityTrayIcon
$antigravityPollSeconds = 300
$claudeRefreshSeconds = $monitorSettings.ClaudeRefreshSeconds
$usageAlertsEnabled = $monitorSettings.UsageAlertsEnabled

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\LLMUsageMonitor', [ref]$createdNew)
if (-not $createdNew) {
    [System.Windows.Forms.MessageBox]::Show('LLM Usage Monitor は既に起動しています。', 'LLM Usage Monitor') | Out-Null
    exit 0
}

$script:snapshot = $null
$script:iconSignatures = @{}
$script:allowExit = $false
$script:lastAlertBands = @{}
$script:lastClaudeDesktopPoll = [DateTimeOffset]::MinValue
$script:claudeUpdateProcess = $null
$script:lastCodexPoll = [DateTimeOffset]::MinValue
$script:codexUpdateProcess = $null
$script:lastAntigravityPoll = [DateTimeOffset]::MinValue
$script:antigravityUpdateProcess = $null
$script:apiProcess = $null
$script:restartRequested = $false
$script:nextLocalRefreshAt = [DateTimeOffset]::Now.AddSeconds($RefreshSeconds)
$script:nextClaudeRefreshAt = [DateTimeOffset]::Now.AddSeconds($claudeRefreshSeconds)
$startupPath = Get-StartupShortcutPath
$thisScript = $MyInvocation.MyCommand.Path

function Get-ActiveWindowPercent {
    param($Window)
    if ($null -eq $Window -or (Test-UsageWindowExpired $Window)) { return $null }
    return [double]$Window.UsedPercent
}

function Format-ResetRemainingShort {
    param($Window, [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    if ($null -eq $Window -or $null -eq $Window.ResetsAtEpoch) { return '?' }
    $seconds = [int64]$Window.ResetsAtEpoch - $Now.ToUnixTimeSeconds()
    if ($seconds -le 0) { return '更新待ち' }
    if ($seconds -lt 3600) { return ('{0}m' -f [Math]::Max(1, [Math]::Floor($seconds / 60))) }
    if ($seconds -lt 86400) { return ('{0}h~' -f [Math]::Floor($seconds / 3600)) }
    return ('{0}d~' -f [Math]::Floor($seconds / 86400))
}

function Get-NextUpdateSeconds {
    param([DateTimeOffset]$NextAt)
    $seconds = [Math]::Ceiling(($NextAt - [DateTimeOffset]::Now).TotalSeconds)
    if ($seconds -le 0) { return 0 }
    return [int64]$seconds
}

function Set-ProviderTrayIcon {
    param(
        [ValidateSet('Codex', 'Claude', 'Antigravity')][string]$Provider,
        $Usage,
        [System.Windows.Forms.NotifyIcon]$TrayIcon
    )
    $five = if ($null -ne $Usage) { Get-ActiveWindowPercent $Usage.FiveHour } else { $null }
    $week = if ($null -ne $Usage) { Get-ActiveWindowPercent $Usage.Weekly } else { $null }
    $resetRemaining = if ($null -ne $Usage) { Get-UsageWindowRemainingPercent $Usage.FiveHour } else { $null }
    $resetBucket = if ($null -eq $resetRemaining) { $null } else { [Math]::Max(0, [Math]::Min(100, [Math]::Ceiling($resetRemaining / 20) * 20)) }
    $scoped = if ($null -ne $Usage) { Get-ActiveWindowPercent (Get-ObjectProperty $Usage 'Fable') } else { $null }
    $signature = '{0}:{1}:{2}:{3}:{4}' -f $Provider, $(if ($null -eq $five) { '?' } else { [Math]::Round($five) }), $(if ($null -eq $week) { '?' } else { [Math]::Round($week) }), $(if ($null -eq $resetBucket) { '?' } else { $resetBucket }), $(if ($null -eq $scoped) { '?' } else { [Math]::Round($scoped) })
    if ($script:iconSignatures[$Provider] -ne $signature) {
        $oldIcon = $TrayIcon.Icon
        $TrayIcon.Icon = New-MonitorTrayIcon $Provider $five $week $resetBucket $scoped
        $script:iconSignatures[$Provider] = $signature
        if ($null -ne $oldIcon) { $oldIcon.Dispose() }
    }
}

function Get-AvailableResetCredits {
    # $null when the source carries no credit data (session-scrape fallback),
    # otherwise the available credits (possibly empty).
    param($Usage)
    $credits = Get-ObjectProperty $Usage 'ResetCredits'
    if ($null -eq $credits) { return $null }
    $available = @(@(Get-ObjectProperty $credits 'credits') | Where-Object { $null -ne $_ -and (Get-ObjectProperty $_ 'status') -eq 'available' })
    return ,$available
}

function Format-ResetCreditsShort {
    param($Usage)
    $available = Get-AvailableResetCredits $Usage
    if ($null -eq $available) { return '' }
    return (' | RC {0}枚' -f $available.Count)
}

function Format-ResetCreditsDetail {
    param($Usage, [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    if ($null -eq $Usage) { return 'リセットクレジット データなし' }
    $available = Get-AvailableResetCredits $Usage
    if ($null -eq $available) { return 'リセットクレジット 不明 (旧取得経路で表示中)' }
    if ($available.Count -eq 0) { return 'リセットクレジット なし' }
    $expiries = @($available | ForEach-Object { ConvertTo-NullableInt64 (Get-ObjectProperty $_ 'expires_at_epoch') } | Where-Object { $null -ne $_ } | Sort-Object)
    if ($expiries.Count -eq 0) { return ('リセットクレジット {0}枚' -f $available.Count) }
    $dates = @($expiries | ForEach-Object { [DateTimeOffset]::FromUnixTimeSeconds($_).ToLocalTime().ToString('M/d') })
    $soonestDays = [Math]::Max(0, [Math]::Floor(([double]$expiries[0] - $Now.ToUnixTimeSeconds()) / 86400))
    return ('リセットクレジット {0}枚  期限 {1} (最短あと{2}日)' -f $available.Count, ($dates -join ', '), $soonestDays)
}

function Update-CountdownDisplay {
    $codexSeconds = Get-NextUpdateSeconds $script:nextLocalRefreshAt
    $claudeSeconds = Get-NextUpdateSeconds $script:nextClaudeRefreshAt
    $antigravitySeconds = Get-NextUpdateSeconds $script:lastAntigravityPoll.AddSeconds($antigravityPollSeconds)
    $codexSummary = Get-ProviderSummary $script:snapshot.Codex
    $claudeSummary = Get-ProviderSummary $script:snapshot.Claude
    $antigravitySummary = Get-ProviderSummary $script:snapshot.Antigravity
    $codexCredits = Format-ResetCreditsShort $script:snapshot.Codex

    if ($codexNotifyIcon.Visible) { Set-ProviderTrayIcon 'Codex' $script:snapshot.Codex $codexNotifyIcon }
    if ($claudeNotifyIcon.Visible) { Set-ProviderTrayIcon 'Claude' $script:snapshot.Claude $claudeNotifyIcon }
    if ($antigravityNotifyIcon.Visible) { Set-ProviderTrayIcon 'Antigravity' $script:snapshot.Antigravity $antigravityNotifyIcon }

    $codexTooltip = 'Codex | {0}{1} | 次回 {2}s' -f $codexSummary, $codexCredits, $codexSeconds
    $claudeTooltip = 'Claude | {0} | 次回 {1}s' -f $claudeSummary, $claudeSeconds
    $antigravityTooltip = 'Antigravity | {0} | 次回 {1}s' -f $antigravitySummary, $antigravitySeconds
    if ($codexTooltip.Length -gt 63) { $codexTooltip = $codexTooltip.Substring(0, 63) }
    if ($claudeTooltip.Length -gt 63) { $claudeTooltip = $claudeTooltip.Substring(0, 63) }
    if ($antigravityTooltip.Length -gt 63) { $antigravityTooltip = $antigravityTooltip.Substring(0, 63) }
    $codexNotifyIcon.Text = $codexTooltip
    $claudeNotifyIcon.Text = $claudeTooltip
    $antigravityNotifyIcon.Text = $antigravityTooltip
    $codexMenu.Text = 'Codex  {0}{1} | 次回 {2}s' -f $codexSummary, $codexCredits, $codexSeconds
    $claudeMenu.Text = 'Claude  {0} | 次回 {1}s' -f $claudeSummary, $claudeSeconds
    $antigravityMenu.Text = 'Antigravity  {0} | 次回 {1}s' -f $antigravitySummary, $antigravitySeconds
    $updatedLabel.Text = '次回 Codex {0}s / Claude {1}s / agy {2}s' -f $codexSeconds, $claudeSeconds, $antigravitySeconds
}

function Write-ClaudeDesktopUsageLog {
    param([string]$Message)
    try {
        $dataDirectory = Join-Path $HOME '.ai-usage'
        New-Item -ItemType Directory -Force -Path $dataDirectory | Out-Null
        $logPath = Join-Path $dataDirectory 'claude-desktop-usage.log'
        $timestamp = [DateTimeOffset]::Now.ToString('o')
        Add-Content -LiteralPath $logPath -Value ('{0} {1}' -f $timestamp, $Message) -Encoding UTF8
    } catch {
    }
}

function Start-ClaudeDesktopUsageUpdate {
    if ($SmokeTest) { return }
    if ($null -ne $script:claudeUpdateProcess -and -not $script:claudeUpdateProcess.HasExited) { return }
    $now = [DateTimeOffset]::Now
    if (($now - $script:lastClaudeDesktopPoll).TotalSeconds -lt $claudeRefreshSeconds) { return }
    $script:lastClaudeDesktopPoll = $now

    $helper = Join-Path $PSScriptRoot 'claude-desktop-usage.py'
    if (-not (Test-Path -LiteralPath $helper)) {
        Write-ClaudeDesktopUsageLog ('helper not found: {0}' -f $helper)
        return
    }
    $python = Get-Command pythonw.exe -ErrorAction SilentlyContinue
    if ($null -eq $python) { $python = Get-Command python.exe -ErrorAction SilentlyContinue }
    if ($null -eq $python) {
        Write-ClaudeDesktopUsageLog 'python.exe/pythonw.exe not found'
        return
    }

    $dataDirectory = Join-Path $HOME '.ai-usage'
    New-Item -ItemType Directory -Force -Path $dataDirectory | Out-Null
    $logPath = Join-Path $dataDirectory 'claude-desktop-usage.log'
    $arguments = '"{0}" --log "{1}"' -f $helper, $logPath
    $script:claudeUpdateProcess = Start-Process -FilePath $python.Source -ArgumentList $arguments -WindowStyle Hidden -PassThru
}

function Get-MonitorPython {
    $python = Get-Command pythonw.exe -ErrorAction SilentlyContinue
    if ($null -eq $python) { $python = Get-Command python.exe -ErrorAction SilentlyContinue }
    return $python
}

function Start-CodexUsageUpdate {
    # Refresh ~/.ai-usage/codex-usage.json from the official app-server rate
    # limits. Metadata read (no model tokens); throttled to avoid spawning the
    # app-server too often.
    if ($SmokeTest) { return }
    if ($null -ne $script:codexUpdateProcess -and -not $script:codexUpdateProcess.HasExited) { return }
    $now = [DateTimeOffset]::Now
    if (($now - $script:lastCodexPoll).TotalSeconds -lt [Math]::Max(60, $RefreshSeconds)) { return }
    $script:lastCodexPoll = $now

    $helper = Join-Path $PSScriptRoot 'codex-usage.py'
    if (-not (Test-Path -LiteralPath $helper)) { return }
    $python = Get-MonitorPython
    if ($null -eq $python) { return }
    $script:codexUpdateProcess = Start-Process -FilePath $python.Source -ArgumentList ('"{0}"' -f $helper) -WindowStyle Hidden -PassThru
}

function Start-AntigravityUsageUpdate {
    # Refresh ~/.ai-usage/agy-usage.json from `agy /usage`. Heavier to spawn, so
    # poll every 5 minutes regardless of the local refresh cadence.
    if ($SmokeTest) { return }
    if ($null -ne $script:antigravityUpdateProcess -and -not $script:antigravityUpdateProcess.HasExited) { return }
    $now = [DateTimeOffset]::Now
    if (($now - $script:lastAntigravityPoll).TotalSeconds -lt $antigravityPollSeconds) { return }
    $script:lastAntigravityPoll = $now

    $helper = Join-Path $PSScriptRoot 'agy-usage.py'
    if (-not (Test-Path -LiteralPath $helper)) { return }
    $python = Get-MonitorPython
    if ($null -eq $python) { return }
    $script:antigravityUpdateProcess = Start-Process -FilePath $python.Source -ArgumentList ('"{0}"' -f $helper) -WindowStyle Hidden -PassThru
}

function Start-UsageApiServer {
    if ($SmokeTest -or $DisableApi) { return }
    $serverScript = Join-Path $PSScriptRoot 'usage_api.py'
    if (-not (Test-Path -LiteralPath $serverScript)) { return }
    $python = Get-Command pythonw.exe -ErrorAction SilentlyContinue
    if ($null -eq $python) { $python = Get-Command python.exe -ErrorAction SilentlyContinue }
    if ($null -eq $python) { return }

    $arguments = '"{0}" --host 127.0.0.1 --port {1}' -f $serverScript, $ApiPort
    $script:apiProcess = Start-Process -FilePath $python.Source -ArgumentList $arguments -WindowStyle Hidden -PassThru
}

function Set-StartupEnabled {
    param([bool]$Enabled)
    Set-MonitorStartupEnabled -Enabled $Enabled -MonitorScript $thisScript
}

function New-UsageGroup {
    param([string]$Title, [int]$Top, [string[]]$RowNames = @('5時間', '週間'), [switch]$WithExtraLine)
    $group = New-Object System.Windows.Forms.GroupBox
    $group.Text = $Title
    $group.Location = New-Object System.Drawing.Point 12, $Top

    $meta = New-Object System.Windows.Forms.Label
    $meta.Location = New-Object System.Drawing.Point 14, 22
    $meta.Size = New-Object System.Drawing.Size 464, 20
    $meta.ForeColor = [System.Drawing.Color]::DimGray
    $controls = @($meta)

    $extra = $null
    $rowTop = 49
    if ($WithExtraLine) {
        $extra = New-Object System.Windows.Forms.Label
        $extra.Location = New-Object System.Drawing.Point 14, 44
        $extra.Size = New-Object System.Drawing.Size 464, 20
        $controls += $extra
        $rowTop = 71
    }

    $rows = @()
    foreach ($name in $RowNames) {
        $label = New-Object System.Windows.Forms.Label
        $label.Location = New-Object System.Drawing.Point 14, $rowTop
        $label.Size = New-Object System.Drawing.Size 462, 20
        $label.AutoEllipsis = $true
        $bar = New-Object System.Windows.Forms.ProgressBar
        $bar.Location = New-Object System.Drawing.Point 17, ($rowTop + 21)
        $bar.Size = New-Object System.Drawing.Size 457, 14
        $controls += $label
        $controls += $bar
        $rows += @{ Name = $name; Label = $label; Bar = $bar }
        $rowTop += 45
    }

    $group.Size = New-Object System.Drawing.Size 496, ($rowTop + 11)
    $group.Controls.AddRange($controls)
    $form.Controls.Add($group)
    return @{ Group = $group; Meta = $meta; Extra = $extra; Rows = $rows }
}

function Set-WindowControls {
    param($Label, $Progress, [string]$Name, $Window)
    if ($null -eq $Window) {
        $Label.Text = "$Name：データなし"
        $Progress.Value = 0
        return
    }
    $value = [Math]::Max(0, [Math]::Min(100, [int][Math]::Round($Window.UsedPercent)))
    $Progress.Value = $value
    if (Test-UsageWindowExpired $Window) {
        $Label.Text = ('{0}：期限経過（次回利用時に更新）' -f $Name)
    } else {
        $Label.Text = ('{0}：{1:0.#}% 使用・残り {2:0.#}%　リセット {3}' -f $Name, $Window.UsedPercent, $Window.LeftPercent, (Format-ResetTime $Window))
    }
}

function Update-ProviderControls {
    # $Windows lines up with the group's rows; defaults to 5-hour / weekly.
    param($Controls, $Usage, [object[]]$Windows = $null)
    if ($null -eq $Usage) {
        $Controls.Meta.Text = 'まだデータがありません'
        foreach ($row in $Controls.Rows) { Set-WindowControls $row.Label $row.Bar $row.Name $null }
        return
    }
    $details = @()
    if ($Usage.Model) { $details += $Usage.Model }
    if ($Usage.Plan) { $details += $Usage.Plan }
    $details += ('更新: {0}' -f (Format-CapturedAt $Usage))
    if ($null -ne $Usage.ContextUsedPercent) { $details += ('context {0:0.#}%' -f $Usage.ContextUsedPercent) }
    $Controls.Meta.Text = $details -join ' / '
    if ($null -eq $Windows) { $Windows = @($Usage.FiveHour, $Usage.Weekly) }
    for ($i = 0; $i -lt $Controls.Rows.Count; $i++) {
        $window = if ($i -lt $Windows.Count) { $Windows[$i] } else { $null }
        Set-WindowControls $Controls.Rows[$i].Label $Controls.Rows[$i].Bar $Controls.Rows[$i].Name $window
    }
}

function Get-AntigravityWindows {
    # Row order: Gemini 5h, Gemini weekly, Claude/GPT 5h, Claude/GPT weekly.
    param($Usage)
    $windows = @($null, $null, $null, $null)
    if ($null -eq $Usage) { return ,$windows }
    $found = $false
    foreach ($family in @(Get-ObjectProperty $Usage 'FamilyUsages')) {
        if ($null -eq $family) { continue }
        $index = switch ($family.Key) { 'gemini' { 0 } 'claude_gpt' { 2 } default { -1 } }
        if ($index -lt 0) { continue }
        $windows[$index] = $family.FiveHour
        $windows[$index + 1] = $family.Weekly
        $found = $true
    }
    if (-not $found) {
        # Older agy-usage.json without families: the primary is Gemini.
        $windows[0] = $Usage.FiveHour
        $windows[1] = $Usage.Weekly
    }
    return ,$windows
}

function Get-ProviderSummary {
    param($Usage)
    if ($null -eq $Usage) { return '待機中' }
    $parts = @()
    if ($null -ne $Usage.FiveHour -and -not (Test-UsageWindowExpired $Usage.FiveHour)) {
        $parts += ('5h {0:0.#}%→{1}' -f $Usage.FiveHour.UsedPercent, (Format-ResetRemainingShort $Usage.FiveHour))
    }
    if ($null -ne $Usage.Weekly -and -not (Test-UsageWindowExpired $Usage.Weekly)) {
        $parts += ('7d {0:0.#}%→{1}' -f $Usage.Weekly.UsedPercent, (Format-ResetRemainingShort $Usage.Weekly))
    }
    $fable = Get-ObjectProperty $Usage 'Fable'
    if ($null -ne $fable -and -not (Test-UsageWindowExpired $fable)) {
        $parts += ('Fable {0:0.#}%' -f $fable.UsedPercent)
    }
    if ($parts.Count -eq 0) { return '更新待ち' }
    return $parts -join ' / '
}

function Check-UsageAlerts {
    param($Usage)
    if (-not $usageAlertsEnabled) { return }
    if ($null -eq $Usage) { return }
    foreach ($pair in @(@('5時間', $Usage.FiveHour), @('週間', $Usage.Weekly), @('Fable週間', (Get-ObjectProperty $Usage 'Fable')))) {
        $window = $pair[1]
        if ($null -eq $window -or (Test-UsageWindowExpired $window)) { continue }
        $key = '{0}:{1}' -f $Usage.Provider, $pair[0]
        $band = if ($window.UsedPercent -ge 95) { 2 } elseif ($window.UsedPercent -ge 80) { 1 } else { 0 }
        if (-not $script:lastAlertBands.ContainsKey($key)) {
            $script:lastAlertBands[$key] = $band
            continue
        }
        if ($band -gt $script:lastAlertBands[$key] -and $band -gt 0) {
            $targetIcon = switch ($Usage.Provider) {
                'Codex' { $codexNotifyIcon }
                'Antigravity' { $antigravityNotifyIcon }
                default { $claudeNotifyIcon }
            }
            if (-not $targetIcon.Visible) { $script:lastAlertBands[$key] = $band; continue }
            $targetIcon.BalloonTipTitle = '{0} の利用制限' -f $Usage.Provider
            $targetIcon.BalloonTipText = '{0}枠を {1:0.#}% 使用しています。' -f $pair[0], $window.UsedPercent
            $targetIcon.BalloonTipIcon = if ($band -ge 2) { [System.Windows.Forms.ToolTipIcon]::Error } else { [System.Windows.Forms.ToolTipIcon]::Warning }
            $targetIcon.ShowBalloonTip(5000)
        }
        $script:lastAlertBands[$key] = $band
    }
}

function Update-Snapshot {
    try {
        $script:snapshot = Get-UsageSnapshot
        Save-UsageSnapshot $script:snapshot
        Update-ProviderControls $codexControls $script:snapshot.Codex
        $codexControls.Extra.Text = Format-ResetCreditsDetail $script:snapshot.Codex
        $claude = $script:snapshot.Claude
        Update-ProviderControls $claudeControls $claude @($claude.FiveHour, $claude.Weekly, (Get-ObjectProperty $claude 'Fable'))
        Update-ProviderControls $antigravityControls $script:snapshot.Antigravity (Get-AntigravityWindows $script:snapshot.Antigravity)
        Update-CountdownDisplay
        Check-UsageAlerts $script:snapshot.Codex
        Check-UsageAlerts $script:snapshot.Claude
        Check-UsageAlerts $script:snapshot.Antigravity
    } catch {
        $updatedLabel.Text = '更新エラー: ' + $_.Exception.Message
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'LLM Usage Monitor'
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.Font = New-Object System.Drawing.Font 'Segoe UI', 9
$form.ShowInTaskbar = $false

$heading = New-Object System.Windows.Forms.Label
$heading.Text = 'LLM 利用状況'
$heading.Font = New-Object System.Drawing.Font 'Segoe UI', 14, ([System.Drawing.FontStyle]::Bold)
$heading.Location = New-Object System.Drawing.Point 12, 10
$heading.Size = New-Object System.Drawing.Size 140, 28
$form.Controls.Add($heading)

$updatedLabel = New-Object System.Windows.Forms.Label
$updatedLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$updatedLabel.Location = New-Object System.Drawing.Point 150, 13
$updatedLabel.Size = New-Object System.Drawing.Size 357, 20
$updatedLabel.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($updatedLabel)

$codexControls = New-UsageGroup 'Codex' 42 -WithExtraLine
$claudeControls = New-UsageGroup 'Claude Code' ($codexControls.Group.Bottom + 8) -RowNames @('5時間', '週間', 'Fable 週間')
$antigravityControls = New-UsageGroup 'Antigravity' ($claudeControls.Group.Bottom + 8) -RowNames @('Gemini 5時間', 'Gemini 週間', 'Claude/GPT 5時間', 'Claude/GPT 週間')
$contentBottom = $antigravityControls.Group.Bottom
$form.ClientSize = New-Object System.Drawing.Size 520, ($contentBottom + 58)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'ウィンドウを閉じてもタスクトレイで動作を続けます。'
$hint.Location = New-Object System.Drawing.Point 14, ($contentBottom + 21)
$hint.Size = New-Object System.Drawing.Size 315, 22
$hint.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($hint)

$settingsButton = New-Object System.Windows.Forms.Button
$settingsButton.Text = '設定...'
$settingsButton.Location = New-Object System.Drawing.Point 418, ($contentBottom + 15)
$settingsButton.Size = New-Object System.Drawing.Size 90, 28
$form.Controls.Add($settingsButton)

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$codexMenu = $menu.Items.Add('Codex  待機中')
$codexMenu.Enabled = $false
$claudeMenu = $menu.Items.Add('Claude  待機中')
$claudeMenu.Enabled = $false
$antigravityMenu = $menu.Items.Add('Antigravity  待機中')
$antigravityMenu.Enabled = $false
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$detailsMenu = $menu.Items.Add('詳細を表示')
$refreshMenu = $menu.Items.Add('今すぐ更新')
$startupMenu = $menu.Items.Add('Windows 起動時に開始')
$startupMenu.CheckOnClick = $false
$settingsMenu = $menu.Items.Add('設定...')
$dataMenu = $menu.Items.Add('データフォルダーを開く')
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$exitMenu = $menu.Items.Add('終了')

$codexNotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$codexNotifyIcon.ContextMenuStrip = $menu
$codexNotifyIcon.Icon = New-MonitorTrayIcon 'Codex' $null $null
$codexNotifyIcon.Text = 'Codex | 外側 5h ? | 内側 7d ?'
$codexNotifyIcon.Visible = $showCodexTrayIcon

$claudeNotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$claudeNotifyIcon.ContextMenuStrip = $menu
$claudeNotifyIcon.Icon = New-MonitorTrayIcon 'Claude' $null $null
$claudeNotifyIcon.Text = 'Claude | 外側 5h ? | 内側 7d ?'
$claudeNotifyIcon.Visible = $showClaudeTrayIcon

$antigravityNotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$antigravityNotifyIcon.ContextMenuStrip = $menu
$antigravityNotifyIcon.Icon = New-MonitorTrayIcon 'Antigravity' $null $null
$antigravityNotifyIcon.Text = 'Antigravity | 外側 Gemini 5h ? | 内側 7d ?'
$antigravityNotifyIcon.Visible = $showAntigravityTrayIcon

$showDetails = {
    Update-Snapshot
    $form.Show()
    $form.Activate()
}
$detailsMenu.Add_Click($showDetails)
$codexNotifyIcon.Add_MouseClick({ param($sender, $eventArgs); if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { & $showDetails } })
$claudeNotifyIcon.Add_MouseClick({ param($sender, $eventArgs); if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { & $showDetails } })
$antigravityNotifyIcon.Add_MouseClick({ param($sender, $eventArgs); if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { & $showDetails } })
$refreshMenu.Add_Click({ Update-Snapshot })
$startupMenu.Add_Click({ Set-StartupEnabled (-not (Test-Path -LiteralPath $startupPath)); $startupMenu.Checked = Test-Path -LiteralPath $startupPath })
$openSettings = {
    if (Show-MonitorSettingsDialog -MonitorScript $thisScript) {
        $script:restartRequested = $true
        $script:allowExit = $true
        $form.Close()
        [System.Windows.Forms.Application]::Exit()
    }
}
$settingsMenu.Add_Click($openSettings)
$settingsButton.Add_Click($openSettings)
$dataMenu.Add_Click({
    $path = Join-Path $HOME '.ai-usage'
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    Start-Process explorer.exe -ArgumentList $path
})
$menu.Add_Opening({ $startupMenu.Checked = Test-Path -LiteralPath $startupPath })
$exitMenu.Add_Click({ $script:allowExit = $true; $form.Close(); [System.Windows.Forms.Application]::Exit() })
$form.Add_FormClosing({ param($sender, $eventArgs); if (-not $script:allowExit) { $eventArgs.Cancel = $true; $form.Hide() } })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [Math]::Max(5, $RefreshSeconds) * 1000
$timer.Add_Tick({
    $script:nextLocalRefreshAt = [DateTimeOffset]::Now.AddSeconds($RefreshSeconds)
    Start-CodexUsageUpdate
    Start-AntigravityUsageUpdate
    Update-Snapshot
})
$timer.Start()

$claudeTimer = New-Object System.Windows.Forms.Timer
$claudeTimer.Interval = [Math]::Max(5, $claudeRefreshSeconds) * 1000
$claudeTimer.Add_Tick({
    $script:nextClaudeRefreshAt = [DateTimeOffset]::Now.AddSeconds($claudeRefreshSeconds)
    Start-ClaudeDesktopUsageUpdate
})
$claudeTimer.Start()

$countdownTimer = New-Object System.Windows.Forms.Timer
$countdownTimer.Interval = 1000
$countdownTimer.Add_Tick({ Update-CountdownDisplay })
$countdownTimer.Start()

try {
    Start-UsageApiServer
    Start-ClaudeDesktopUsageUpdate
    Start-CodexUsageUpdate
    Start-AntigravityUsageUpdate
    Update-Snapshot
    if ($SmokeTest) {
        Write-Host 'LLM Usage Monitor smoke test passed.'
    } else {
        [System.Windows.Forms.Application]::Run()
    }
} finally {
    $timer.Stop(); $timer.Dispose()
    $claudeTimer.Stop(); $claudeTimer.Dispose()
    $countdownTimer.Stop(); $countdownTimer.Dispose()
    if ($null -ne $script:apiProcess -and -not $script:apiProcess.HasExited) {
        Stop-Process -Id $script:apiProcess.Id -Force -ErrorAction SilentlyContinue
    }
    foreach ($trayIcon in @($codexNotifyIcon, $claudeNotifyIcon, $antigravityNotifyIcon)) {
        $trayIcon.Visible = $false
        if ($null -ne $trayIcon.Icon) { $trayIcon.Icon.Dispose() }
        $trayIcon.Dispose()
    }
    $form.Dispose()
    if ($createdNew) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
    if ($script:restartRequested) {
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $thisScript)
    }
}
