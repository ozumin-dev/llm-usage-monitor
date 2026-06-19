[CmdletBinding()]
param(
    [int]$RefreshSeconds = 30,
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UsageData.ps1')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'TrayIcon.ps1')
[System.Windows.Forms.Application]::EnableVisualStyles()

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
$startupPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\LLM Usage Monitor.lnk'
$thisScript = $MyInvocation.MyCommand.Path

function Get-ActiveWindowPercent {
    param($Window)
    if ($null -eq $Window -or (Test-UsageWindowExpired $Window)) { return $null }
    return [double]$Window.UsedPercent
}

function Set-ProviderTrayIcon {
    param(
        [ValidateSet('Codex', 'Claude')][string]$Provider,
        $Usage,
        [System.Windows.Forms.NotifyIcon]$TrayIcon
    )
    $five = if ($null -ne $Usage) { Get-ActiveWindowPercent $Usage.FiveHour } else { $null }
    $week = if ($null -ne $Usage) { Get-ActiveWindowPercent $Usage.Weekly } else { $null }
    $signature = '{0}:{1}:{2}' -f $Provider, $(if ($null -eq $five) { '?' } else { [Math]::Round($five) }), $(if ($null -eq $week) { '?' } else { [Math]::Round($week) })
    if ($script:iconSignatures[$Provider] -ne $signature) {
        $oldIcon = $TrayIcon.Icon
        $TrayIcon.Icon = New-ProviderUsageIcon $Provider $five $week
        $script:iconSignatures[$Provider] = $signature
        if ($null -ne $oldIcon) { $oldIcon.Dispose() }
    }
    $label = if ($Provider -eq 'Claude') { 'Claude' } else { 'Codex' }
    $fiveText = if ($null -eq $five) { '?' } else { '{0:0.#}%' -f $five }
    $weekText = if ($null -eq $week) { '?' } else { '{0:0.#}%' -f $week }
    $TrayIcon.Text = '{0} | 外側 5h {1} | 内側 7d {2}' -f $label, $fiveText, $weekText
}

function Start-ClaudeDesktopUsageUpdate {
    if ($SmokeTest) { return }
    $now = [DateTimeOffset]::Now
    if (($now - $script:lastClaudeDesktopPoll).TotalMinutes -lt 5) { return }
    $script:lastClaudeDesktopPoll = $now

    $helper = Join-Path $PSScriptRoot 'claude-desktop-usage.py'
    if (-not (Test-Path -LiteralPath $helper)) { return }
    $python = Get-Command pythonw.exe -ErrorAction SilentlyContinue
    if ($null -eq $python) { $python = Get-Command python.exe -ErrorAction SilentlyContinue }
    if ($null -eq $python) { return }

    $arguments = '"{0}"' -f $helper
    Start-Process -FilePath $python.Source -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}

function Set-StartupEnabled {
    param([bool]$Enabled)
    if ($Enabled) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($startupPath)
        $shortcut.TargetPath = (Get-Command powershell.exe).Source
        $shortcut.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $thisScript
        $shortcut.WorkingDirectory = Split-Path -Parent $thisScript
        $shortcut.Description = 'LLM Usage Monitor'
        $shortcut.Save()
    } elseif (Test-Path -LiteralPath $startupPath) {
        Remove-Item -LiteralPath $startupPath -Force
    }
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
    if ($null -ne $Usage.FiveHour -and -not (Test-UsageWindowExpired $Usage.FiveHour)) { $parts += ('5h {0:0.#}%' -f $Usage.FiveHour.UsedPercent) }
    if ($null -ne $Usage.Weekly -and -not (Test-UsageWindowExpired $Usage.Weekly)) { $parts += ('7d {0:0.#}%' -f $Usage.Weekly.UsedPercent) }
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
        Start-ClaudeDesktopUsageUpdate
        $script:snapshot = Get-UsageSnapshot
        Update-ProviderControls $codexControls $script:snapshot.Codex
        Update-ProviderControls $claudeControls $script:snapshot.Claude
        $updatedLabel.Text = '最終確認: {0}' -f (Get-Date -Format 'H:mm:ss')

        Set-ProviderTrayIcon 'Codex' $script:snapshot.Codex $codexNotifyIcon
        Set-ProviderTrayIcon 'Claude' $script:snapshot.Claude $claudeNotifyIcon
        $codexMenu.Text = 'Codex　' + (Get-ProviderSummary $script:snapshot.Codex)
        $claudeMenu.Text = 'Claude　' + (Get-ProviderSummary $script:snapshot.Claude)
        Check-UsageAlerts $script:snapshot.Codex
        Check-UsageAlerts $script:snapshot.Claude
    } catch {
        $updatedLabel.Text = '更新エラー: ' + $_.Exception.Message
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'LLM Usage Monitor'
$form.ClientSize = New-Object System.Drawing.Size 448, 380
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
$heading.Size = New-Object System.Drawing.Size 250, 28
$form.Controls.Add($heading)

$updatedLabel = New-Object System.Windows.Forms.Label
$updatedLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$updatedLabel.Location = New-Object System.Drawing.Point 265, 13
$updatedLabel.Size = New-Object System.Drawing.Size 170, 20
$updatedLabel.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($updatedLabel)

$codexControls = New-UsageGroup 'Codex' 42
$claudeControls = New-UsageGroup 'Claude Code' 202

$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'ウィンドウを閉じてもタスクトレイで動作を続けます。'
$hint.Location = New-Object System.Drawing.Point 14, 360
$hint.Size = New-Object System.Drawing.Size 420, 18
$hint.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($hint)

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
$dataMenu = $menu.Items.Add('データフォルダーを開く')
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$exitMenu = $menu.Items.Add('終了')

$codexNotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$codexNotifyIcon.ContextMenuStrip = $menu
$codexNotifyIcon.Icon = New-ProviderUsageIcon 'Codex' $null $null
$codexNotifyIcon.Text = 'Codex | 外側 5h ? | 内側 7d ?'
$codexNotifyIcon.Visible = $true

$claudeNotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$claudeNotifyIcon.ContextMenuStrip = $menu
$claudeNotifyIcon.Icon = New-ProviderUsageIcon 'Claude' $null $null
$claudeNotifyIcon.Text = 'Claude | 外側 5h ? | 内側 7d ?'
$claudeNotifyIcon.Visible = $true

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
$dataMenu.Add_Click({
    $path = Join-Path $HOME '.ai-usage'
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    Start-Process explorer.exe -ArgumentList $path
})
$menu.Add_Opening({ $startupMenu.Checked = Test-Path -LiteralPath $startupPath })
$exitMenu.Add_Click({ $script:allowExit = $true; $form.Close(); [System.Windows.Forms.Application]::Exit() })
$form.Add_FormClosing({ param($sender, $eventArgs); if (-not $script:allowExit) { $eventArgs.Cancel = $true; $form.Hide() } })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [Math]::Max(15, $RefreshSeconds) * 1000
$timer.Add_Tick({ Update-Snapshot })
$timer.Start()

try {
    Update-Snapshot
    if ($SmokeTest) {
        Write-Host 'LLM Usage Monitor smoke test passed.'
    } else {
        [System.Windows.Forms.Application]::Run()
    }
} finally {
    $timer.Stop(); $timer.Dispose()
    foreach ($trayIcon in @($codexNotifyIcon, $claudeNotifyIcon)) {
        $trayIcon.Visible = $false
        if ($null -ne $trayIcon.Icon) { $trayIcon.Icon.Dispose() }
        $trayIcon.Dispose()
    }
    $form.Dispose()
    if ($createdNew) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
