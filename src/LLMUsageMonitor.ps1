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
[System.Windows.Forms.Application]::EnableVisualStyles()

$monitorSettings = Get-MonitorSettings
if (-not $PSBoundParameters.ContainsKey('RefreshSeconds')) { $RefreshSeconds = $monitorSettings.LocalRefreshSeconds }
if (-not $PSBoundParameters.ContainsKey('ApiPort')) { $ApiPort = $monitorSettings.ApiPort }
if (-not $PSBoundParameters.ContainsKey('DisableApi')) { $DisableApi = -not $monitorSettings.ApiEnabled }
$showCodexTrayIcon = $monitorSettings.ShowCodexTrayIcon
$showClaudeTrayIcon = $monitorSettings.ShowClaudeTrayIcon
$claudeRefreshSeconds = $monitorSettings.ClaudeRefreshSeconds

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
    return [Math]::Max(0, [Math]::Ceiling(($NextAt - [DateTimeOffset]::Now).TotalSeconds))
}

function Get-UpdateRemainingPercent {
    param([DateTimeOffset]$NextAt, [double]$IntervalSeconds)
    if ($IntervalSeconds -le 0) { return 0 }
    $remaining = ($NextAt - [DateTimeOffset]::Now).TotalSeconds
    return [Math]::Max(0, [Math]::Min(100, ($remaining / $IntervalSeconds) * 100))
}

function Set-ProviderTrayIcon {
    param(
        [ValidateSet('Codex', 'Claude')][string]$Provider,
        $Usage,
        [System.Windows.Forms.NotifyIcon]$TrayIcon,
        [double]$UpdateRemainingPercent = 100
    )
    $five = if ($null -ne $Usage) { Get-ActiveWindowPercent $Usage.FiveHour } else { $null }
    $week = if ($null -ne $Usage) { Get-ActiveWindowPercent $Usage.Weekly } else { $null }
    $countdownBucket = [Math]::Max(0, [Math]::Min(100, [Math]::Ceiling($UpdateRemainingPercent / 20) * 20))
    $signature = '{0}:{1}:{2}:{3}' -f $Provider, $(if ($null -eq $five) { '?' } else { [Math]::Round($five) }), $(if ($null -eq $week) { '?' } else { [Math]::Round($week) }), $countdownBucket
    if ($script:iconSignatures[$Provider] -ne $signature) {
        $oldIcon = $TrayIcon.Icon
        $TrayIcon.Icon = New-ProviderUsageIcon $Provider $five $week $countdownBucket
        $script:iconSignatures[$Provider] = $signature
        if ($null -ne $oldIcon) { $oldIcon.Dispose() }
    }
}

function Update-CountdownDisplay {
    $codexSeconds = Get-NextUpdateSeconds $script:nextLocalRefreshAt
    $claudeSeconds = Get-NextUpdateSeconds $script:nextClaudeRefreshAt
    $codexRemaining = Get-UpdateRemainingPercent $script:nextLocalRefreshAt $RefreshSeconds
    $claudeRemaining = Get-UpdateRemainingPercent $script:nextClaudeRefreshAt $claudeRefreshSeconds
    $codexSummary = Get-ProviderSummary $script:snapshot.Codex
    $claudeSummary = Get-ProviderSummary $script:snapshot.Claude

    if ($codexNotifyIcon.Visible) { Set-ProviderTrayIcon 'Codex' $script:snapshot.Codex $codexNotifyIcon $codexRemaining }
    if ($claudeNotifyIcon.Visible) { Set-ProviderTrayIcon 'Claude' $script:snapshot.Claude $claudeNotifyIcon $claudeRemaining }

    $codexTooltip = 'Codex | {0} | 次回 {1}s' -f $codexSummary, $codexSeconds
    $claudeTooltip = 'Claude | {0} | 次回 {1}s' -f $claudeSummary, $claudeSeconds
    if ($codexTooltip.Length -gt 63) { $codexTooltip = $codexTooltip.Substring(0, 63) }
    if ($claudeTooltip.Length -gt 63) { $claudeTooltip = $claudeTooltip.Substring(0, 63) }
    $codexNotifyIcon.Text = $codexTooltip
    $claudeNotifyIcon.Text = $claudeTooltip
    $codexMenu.Text = 'Codex　{0} | 次回 {1}s' -f $codexSummary, $codexSeconds
    $claudeMenu.Text = 'Claude　{0} | 次回 {1}s' -f $claudeSummary, $claudeSeconds
    $updatedLabel.Text = '次回 Codex {0}s / Claude {1}s' -f $codexSeconds, $claudeSeconds
}

function Start-ClaudeDesktopUsageUpdate {
    if ($SmokeTest) { return }
    if ($null -ne $script:claudeUpdateProcess -and -not $script:claudeUpdateProcess.HasExited) { return }
    $now = [DateTimeOffset]::Now
    if (($now - $script:lastClaudeDesktopPoll).TotalSeconds -lt $claudeRefreshSeconds) { return }
    $script:lastClaudeDesktopPoll = $now

    $helper = Join-Path $PSScriptRoot 'claude-desktop-usage.py'
    if (-not (Test-Path -LiteralPath $helper)) { return }
    $python = Get-Command pythonw.exe -ErrorAction SilentlyContinue
    if ($null -eq $python) { $python = Get-Command python.exe -ErrorAction SilentlyContinue }
    if ($null -eq $python) { return }

    $arguments = '"{0}"' -f $helper
    $script:claudeUpdateProcess = Start-Process -FilePath $python.Source -ArgumentList $arguments -WindowStyle Hidden -PassThru
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
    param([string]$Title, [int]$Top)
    $group = New-Object System.Windows.Forms.GroupBox
    $group.Text = $Title
    $group.Location = New-Object System.Drawing.Point 12, $Top
    $group.Size = New-Object System.Drawing.Size 424, 150

    $meta = New-Object System.Windows.Forms.Label
    $meta.Location = New-Object System.Drawing.Point 14, 22
    $meta.Size = New-Object System.Drawing.Size 392, 20
    $meta.ForeColor = [System.Drawing.Color]::DimGray

    $fiveLabel = New-Object System.Windows.Forms.Label
    $fiveLabel.Location = New-Object System.Drawing.Point 14, 49
    $fiveLabel.Size = New-Object System.Drawing.Size 390, 20
    $fiveBar = New-Object System.Windows.Forms.ProgressBar
    $fiveBar.Location = New-Object System.Drawing.Point 17, 70
    $fiveBar.Size = New-Object System.Drawing.Size 385, 14

    $weekLabel = New-Object System.Windows.Forms.Label
    $weekLabel.Location = New-Object System.Drawing.Point 14, 94
    $weekLabel.Size = New-Object System.Drawing.Size 390, 20
    $weekBar = New-Object System.Windows.Forms.ProgressBar
    $weekBar.Location = New-Object System.Drawing.Point 17, 115
    $weekBar.Size = New-Object System.Drawing.Size 385, 14

    $group.Controls.AddRange(@($meta, $fiveLabel, $fiveBar, $weekLabel, $weekBar))
    $form.Controls.Add($group)
    return @{ Group = $group; Meta = $meta; FiveLabel = $fiveLabel; FiveBar = $fiveBar; WeekLabel = $weekLabel; WeekBar = $weekBar }
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
    param($Controls, $Usage)
    if ($null -eq $Usage) {
        $Controls.Meta.Text = 'まだデータがありません'
        Set-WindowControls $Controls.FiveLabel $Controls.FiveBar '5時間' $null
        Set-WindowControls $Controls.WeekLabel $Controls.WeekBar '週間' $null
        return
    }
    $details = @()
    if ($Usage.Model) { $details += $Usage.Model }
    if ($Usage.Plan) { $details += $Usage.Plan }
    $details += ('更新: {0}' -f (Format-CapturedAt $Usage))
    if ($null -ne $Usage.ContextUsedPercent) { $details += ('context {0:0.#}%' -f $Usage.ContextUsedPercent) }
    $Controls.Meta.Text = $details -join ' / '
    Set-WindowControls $Controls.FiveLabel $Controls.FiveBar '5時間' $Usage.FiveHour
    Set-WindowControls $Controls.WeekLabel $Controls.WeekBar '週間' $Usage.Weekly
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
    if ($parts.Count -eq 0) { return '更新待ち' }
    return $parts -join ' / '
}

function Check-UsageAlerts {
    param($Usage)
    if ($null -eq $Usage) { return }
    foreach ($pair in @(@('5時間', $Usage.FiveHour), @('週間', $Usage.Weekly))) {
        $window = $pair[1]
        if ($null -eq $window -or (Test-UsageWindowExpired $window)) { continue }
        $key = '{0}:{1}' -f $Usage.Provider, $pair[0]
        $band = if ($window.UsedPercent -ge 95) { 2 } elseif ($window.UsedPercent -ge 80) { 1 } else { 0 }
        if (-not $script:lastAlertBands.ContainsKey($key)) {
            $script:lastAlertBands[$key] = $band
            continue
        }
        if ($band -gt $script:lastAlertBands[$key] -and $band -gt 0) {
            $targetIcon = if ($Usage.Provider -eq 'Codex') { $codexNotifyIcon } else { $claudeNotifyIcon }
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
        Update-ProviderControls $claudeControls $script:snapshot.Claude
        Update-CountdownDisplay
        Check-UsageAlerts $script:snapshot.Codex
        Check-UsageAlerts $script:snapshot.Claude
    } catch {
        $updatedLabel.Text = '更新エラー: ' + $_.Exception.Message
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'LLM Usage Monitor'
$form.ClientSize = New-Object System.Drawing.Size 448, 410
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
$heading.Size = New-Object System.Drawing.Size 170, 28
$form.Controls.Add($heading)

$updatedLabel = New-Object System.Windows.Forms.Label
$updatedLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$updatedLabel.Location = New-Object System.Drawing.Point 175, 13
$updatedLabel.Size = New-Object System.Drawing.Size 260, 20
$updatedLabel.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($updatedLabel)

$codexControls = New-UsageGroup 'Codex' 42
$claudeControls = New-UsageGroup 'Claude Code' 202

$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'ウィンドウを閉じてもタスクトレイで動作を続けます。'
$hint.Location = New-Object System.Drawing.Point 14, 373
$hint.Size = New-Object System.Drawing.Size 315, 22
$hint.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($hint)

$settingsButton = New-Object System.Windows.Forms.Button
$settingsButton.Text = '設定...'
$settingsButton.Location = New-Object System.Drawing.Point 346, 367
$settingsButton.Size = New-Object System.Drawing.Size 90, 28
$form.Controls.Add($settingsButton)

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$codexMenu = $menu.Items.Add('Codex　待機中')
$codexMenu.Enabled = $false
$claudeMenu = $menu.Items.Add('Claude　待機中')
$claudeMenu.Enabled = $false
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
$codexNotifyIcon.Icon = New-ProviderUsageIcon 'Codex' $null $null
$codexNotifyIcon.Text = 'Codex | 外側 5h ? | 内側 7d ?'
$codexNotifyIcon.Visible = $showCodexTrayIcon

$claudeNotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$claudeNotifyIcon.ContextMenuStrip = $menu
$claudeNotifyIcon.Icon = New-ProviderUsageIcon 'Claude' $null $null
$claudeNotifyIcon.Text = 'Claude | 外側 5h ? | 内側 7d ?'
$claudeNotifyIcon.Visible = $showClaudeTrayIcon

$showDetails = {
    Update-Snapshot
    $form.Show()
    $form.Activate()
}
$detailsMenu.Add_Click($showDetails)
$codexNotifyIcon.Add_MouseClick({ param($sender, $eventArgs); if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { & $showDetails } })
$claudeNotifyIcon.Add_MouseClick({ param($sender, $eventArgs); if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { & $showDetails } })
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
    foreach ($trayIcon in @($codexNotifyIcon, $claudeNotifyIcon)) {
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
