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
$usageAlertsEnabled = $monitorSettings.UsageAlertsEnabled
# Per provider: whether to fetch at all, the fetch interval and the helper that
# writes ~/.ai-usage/<provider>-usage.json. A disabled provider is neither
# fetched nor read, and its tray icon stays hidden.
$providerConfig = [ordered]@{
    Codex = @{ Enabled = $monitorSettings.CodexEnabled; Seconds = $monitorSettings.CodexRefreshSeconds; Helper = 'codex-usage.py'; ShowIcon = $monitorSettings.ShowCodexTrayIcon }
    Claude = @{ Enabled = $monitorSettings.ClaudeEnabled; Seconds = $monitorSettings.ClaudeRefreshSeconds; Helper = 'claude-desktop-usage.py'; ShowIcon = $monitorSettings.ShowClaudeTrayIcon }
    Antigravity = @{ Enabled = $monitorSettings.AntigravityEnabled; Seconds = $monitorSettings.AntigravityRefreshSeconds; Helper = 'agy-usage.py'; ShowIcon = $monitorSettings.ShowAntigravityTrayIcon }
}
$disabledProviders = @($providerConfig.Keys | Where-Object { -not $providerConfig[$_].Enabled })

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
$script:nextFetchAt = @{}
$script:helperProcesses = @{}
# Failures the monitor sees itself; the helpers' own error files take precedence.
$script:monitorErrors = @{}
$script:notifiedErrors = @{}
foreach ($name in $providerConfig.Keys) { $script:nextFetchAt[$name] = [DateTimeOffset]::Now; $script:helperProcesses[$name] = $null }
# The window re-reads the fetched files on this cadence and whenever a helper finishes.
$script:nextSnapshotAt = [DateTimeOffset]::Now.AddSeconds($RefreshSeconds)
$script:apiProcess = $null
$script:restartRequested = $false
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

function Format-NextFetch {
    # '42s' until the next fetch, '取得中' while the helper runs, 'オフ' when disabled.
    param([string]$Provider)
    if (-not $providerConfig[$Provider].Enabled) { return 'オフ' }
    $process = $script:helperProcesses[$Provider]
    if ($null -ne $process -and -not $process.HasExited) { return '取得中' }
    return ('{0}s' -f (Get-NextUpdateSeconds $script:nextFetchAt[$Provider]))
}

function Update-CountdownDisplay {
    $trays = @(
        @{ Name = 'Codex'; Icon = $codexNotifyIcon; Menu = $codexMenu },
        @{ Name = 'Claude'; Icon = $claudeNotifyIcon; Menu = $claudeMenu },
        @{ Name = 'Antigravity'; Icon = $antigravityNotifyIcon; Menu = $antigravityMenu }
    )
    foreach ($tray in $trays) {
        $usage = Get-ObjectProperty $script:snapshot $tray.Name
        $next = Format-NextFetch $tray.Name
        if (-not $providerConfig[$tray.Name].Enabled) {
            $line = '取得オフ'
        } else {
            $extra = if ($tray.Name -eq 'Codex') { Format-ResetCreditsShort $usage } else { '' }
            $line = '{0}{1} | 次回 {2}' -f (Get-ProviderSummary $usage), $extra, $next
            # Leads the line so the 63-char tooltip limit never cuts it off.
            if ($null -ne (Get-SnapshotError $script:snapshot $tray.Name)) { $line = '[取得エラー] ' + $line }
        }
        if ($tray.Icon.Visible) { Set-ProviderTrayIcon $tray.Name $usage $tray.Icon }
        $tooltip = '{0} | {1}' -f $tray.Name, $line
        if ($tooltip.Length -gt 63) { $tooltip = $tooltip.Substring(0, 63) }
        $tray.Icon.Text = $tooltip
        $tray.Menu.Text = '{0}  {1}' -f $tray.Name, $line
    }
    $updatedLabel.Text = '次回取得 Codex {0} / Claude {1} / agy {2}' -f (Format-NextFetch 'Codex'), (Format-NextFetch 'Claude'), (Format-NextFetch 'Antigravity')
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

function Get-MonitorPython {
    $python = Get-Command pythonw.exe -ErrorAction SilentlyContinue
    if ($null -eq $python) { $python = Get-Command python.exe -ErrorAction SilentlyContinue }
    return $python
}

function Start-ProviderFetch {
    # Spawn the provider's helper. Every helper only reads usage metadata (no
    # model tokens): Codex app-server rate limits, Claude OAuth usage, `agy /usage`.
    param([string]$Provider)
    $helper = Join-Path $PSScriptRoot $providerConfig[$Provider].Helper
    if (-not (Test-Path -LiteralPath $helper)) {
        if ($Provider -eq 'Claude') { Write-ClaudeDesktopUsageLog ('helper not found: {0}' -f $helper) }
        Set-MonitorError $Provider ('取得プログラムが見つかりません: {0}' -f $helper)
        return
    }
    $python = Get-MonitorPython
    if ($null -eq $python) {
        if ($Provider -eq 'Claude') { Write-ClaudeDesktopUsageLog 'python.exe/pythonw.exe not found' }
        Set-MonitorError $Provider 'python.exe / pythonw.exe が見つかりません'
        return
    }
    $arguments = '"{0}"' -f $helper
    if ($Provider -eq 'Claude') {
        $dataDirectory = Join-Path $HOME '.ai-usage'
        New-Item -ItemType Directory -Force -Path $dataDirectory | Out-Null
        $arguments += ' --log "{0}"' -f (Join-Path $dataDirectory 'claude-desktop-usage.log')
    }
    $process = Start-Process -FilePath $python.Source -ArgumentList $arguments -WindowStyle Hidden -PassThru
    # Touch the handle now; otherwise ExitCode can read as null after the exit.
    $null = $process.Handle
    $script:helperProcesses[$Provider] = $process
}

function Set-MonitorError {
    param([string]$Provider, [string]$Message)
    $script:monitorErrors[$Provider] = New-ProviderFetchError $Message $script:monitorErrors[$Provider]
}

function Receive-HelperExit {
    # A helper that exits non-zero normally explains itself in its error file;
    # this entry only shows when it died before writing one.
    param([string]$Provider, $Process)
    $code = $Process.ExitCode
    if ($null -eq $code) { return }
    if ($code -eq 0) {
        $script:monitorErrors.Remove($Provider)
    } else {
        Set-MonitorError $Provider ('取得プログラムが終了コード {0} で終了しました' -f $code)
    }
}

function Invoke-FetchScheduler {
    # Called every second: start helpers that are due, and re-read the files
    # as soon as a helper finishes (or on the regular re-read cadence).
    $now = [DateTimeOffset]::Now
    $finished = $false
    foreach ($name in $providerConfig.Keys) {
        if (-not $providerConfig[$name].Enabled) { continue }
        $process = $script:helperProcesses[$name]
        if ($null -ne $process) {
            if (-not $process.HasExited) { continue }
            Receive-HelperExit $name $process
            $script:helperProcesses[$name] = $null
            $finished = $true
        }
        if ($SmokeTest) { continue }
        if ($now -ge $script:nextFetchAt[$name]) {
            $script:nextFetchAt[$name] = $now.AddSeconds($providerConfig[$name].Seconds)
            Start-ProviderFetch $name
        }
    }
    if ($finished -or $now -ge $script:nextSnapshotAt) {
        Update-Snapshot
    } else {
        Update-CountdownDisplay
    }
}

function Request-FetchNow {
    foreach ($name in $providerConfig.Keys) { $script:nextFetchAt[$name] = [DateTimeOffset]::Now }
    Invoke-FetchScheduler
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

    # Fetch error box: hidden while fetching works, otherwise the group grows
    # to show it and the groups below move down (Update-FormLayout).
    $errorBox = New-Object System.Windows.Forms.Label
    $errorBox.Location = New-Object System.Drawing.Point 14, ($rowTop + 4)
    $errorBox.Size = New-Object System.Drawing.Size 462, 48
    $errorBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $errorBox.BackColor = [System.Drawing.Color]::FromArgb(255, 235, 235)
    $errorBox.ForeColor = [System.Drawing.Color]::FromArgb(160, 20, 20)
    $errorBox.Padding = New-Object System.Windows.Forms.Padding 4, 3, 4, 3
    $errorBox.AutoEllipsis = $true
    $errorBox.Visible = $false
    $controls += $errorBox

    $baseHeight = $rowTop + 11
    $group.Size = New-Object System.Drawing.Size 496, $baseHeight
    $group.Controls.AddRange($controls)
    $form.Controls.Add($group)
    return @{ Group = $group; Meta = $meta; Extra = $extra; Rows = $rows; ErrorBox = $errorBox; BaseHeight = $baseHeight }
}

function Format-FetchErrorSummary {
    # One line for tooltips, menus and balloons.
    param($FetchError)
    if ($null -ne $FetchError.Hint -and "$($FetchError.Hint)" -ne '') { return [string]$FetchError.Hint }
    return [string]$FetchError.Message
}

function Set-ProviderErrorBox {
    param($Controls, $FetchError)
    $box = $Controls.ErrorBox
    if ($null -eq $FetchError) {
        $box.Visible = $false
        $errorToolTip.SetToolTip($box, $null)
        $Controls.Group.Height = $Controls.BaseHeight
        return
    }
    $when = @()
    if ($null -ne $FetchError.Since) { $when += ('{0} から失敗中' -f $FetchError.Since.ToLocalTime().ToString('M/d H:mm')) }
    if ($null -ne $FetchError.Count) { $when += ('{0:N0}回' -f $FetchError.Count) }
    $heading = '取得エラー'
    if ($when.Count -gt 0) { $heading += ' (' + ($when -join ', ') + ')' }
    $heading += ' 表示中の値は最後に取れたものです'
    $box.Text = $heading + [Environment]::NewLine + (Format-FetchErrorSummary $FetchError)
    $detail = [string]$FetchError.Message
    if ($null -ne $FetchError.LastAt) { $detail += [Environment]::NewLine + ('最終試行 {0}' -f $FetchError.LastAt.ToLocalTime().ToString('M/d H:mm:ss')) }
    $errorToolTip.SetToolTip($box, $detail)
    $box.Visible = $true
    $Controls.Group.Height = $Controls.BaseHeight + $box.Height + 4
}

function Update-FormLayout {
    # Stack the provider groups and move the footer under them.
    $top = 42
    foreach ($controls in @($codexControls, $claudeControls, $antigravityControls)) {
        $controls.Group.Top = $top
        $top = $controls.Group.Bottom + 8
    }
    $contentBottom = $antigravityControls.Group.Bottom
    $hint.Top = $contentBottom + 21
    $settingsButton.Top = $contentBottom + 15
    $form.ClientSize = New-Object System.Drawing.Size 520, ($contentBottom + 58)
}

function Show-FetchErrorNotifications {
    # One balloon when a provider starts failing (keyed by the failure's start
    # time), so a broken fetch never goes unnoticed; nothing more until it recovers.
    foreach ($name in @('Codex', 'Claude', 'Antigravity')) {
        $fetchError = Get-SnapshotError $script:snapshot $name
        if ($null -eq $fetchError) { $script:notifiedErrors.Remove($name); continue }
        $key = if ($null -ne $fetchError.Since) { $fetchError.Since.ToString('o') } else { $fetchError.Message }
        if ($script:notifiedErrors[$name] -eq $key) { continue }
        $script:notifiedErrors[$name] = $key
        $targetIcon = switch ($name) { 'Codex' { $codexNotifyIcon } 'Antigravity' { $antigravityNotifyIcon } default { $claudeNotifyIcon } }
        if (-not $targetIcon.Visible) { continue }
        $text = Format-FetchErrorSummary $fetchError
        if ($text.Length -gt 200) { $text = $text.Substring(0, 197) + '...' }
        $targetIcon.BalloonTipTitle = '{0} の利用状況を取得できません' -f $name
        $targetIcon.BalloonTipText = $text
        $targetIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Error
        $targetIcon.ShowBalloonTip(8000)
    }
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
    param($Controls, $Usage, [object[]]$Windows = $null, [switch]$Disabled)
    if ($Disabled) {
        $Controls.Meta.Text = '取得しない設定です(設定画面で変更できます)'
        foreach ($row in $Controls.Rows) { Set-WindowControls $row.Label $row.Bar $row.Name $null }
        return
    }
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
    $script:nextSnapshotAt = [DateTimeOffset]::Now.AddSeconds($RefreshSeconds)
    try {
        $script:snapshot = Get-UsageSnapshot -Disabled $disabledProviders -MonitorErrors $script:monitorErrors
        Save-UsageSnapshot $script:snapshot
        $codexOff = $disabledProviders -contains 'Codex'
        Update-ProviderControls $codexControls $script:snapshot.Codex -Disabled:$codexOff
        $codexControls.Extra.Text = if ($codexOff) { '' } else { Format-ResetCreditsDetail $script:snapshot.Codex }
        $claude = $script:snapshot.Claude
        $claudeWindows = @((Get-ObjectProperty $claude 'FiveHour'), (Get-ObjectProperty $claude 'Weekly'), (Get-ObjectProperty $claude 'Fable'))
        Update-ProviderControls $claudeControls $claude $claudeWindows -Disabled:($disabledProviders -contains 'Claude')
        Update-ProviderControls $antigravityControls $script:snapshot.Antigravity (Get-AntigravityWindows $script:snapshot.Antigravity) -Disabled:($disabledProviders -contains 'Antigravity')
        Set-ProviderErrorBox $codexControls (Get-SnapshotError $script:snapshot 'Codex')
        Set-ProviderErrorBox $claudeControls (Get-SnapshotError $script:snapshot 'Claude')
        Set-ProviderErrorBox $antigravityControls (Get-SnapshotError $script:snapshot 'Antigravity')
        Update-FormLayout
        Show-FetchErrorNotifications
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

$errorToolTip = New-Object System.Windows.Forms.ToolTip
$errorToolTip.AutoPopDelay = 30000

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
$codexNotifyIcon.Visible = $providerConfig.Codex.Enabled -and $providerConfig.Codex.ShowIcon

$claudeNotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$claudeNotifyIcon.ContextMenuStrip = $menu
$claudeNotifyIcon.Icon = New-MonitorTrayIcon 'Claude' $null $null
$claudeNotifyIcon.Text = 'Claude | 外側 5h ? | 内側 7d ?'
$claudeNotifyIcon.Visible = $providerConfig.Claude.Enabled -and $providerConfig.Claude.ShowIcon

$antigravityNotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$antigravityNotifyIcon.ContextMenuStrip = $menu
$antigravityNotifyIcon.Icon = New-MonitorTrayIcon 'Antigravity' $null $null
$antigravityNotifyIcon.Text = 'Antigravity | 外側 Gemini 5h ? | 内側 7d ?'
$antigravityNotifyIcon.Visible = $providerConfig.Antigravity.Enabled -and $providerConfig.Antigravity.ShowIcon

$showDetails = {
    Update-Snapshot
    $form.Show()
    $form.Activate()
}
$detailsMenu.Add_Click($showDetails)
$codexNotifyIcon.Add_MouseClick({ param($sender, $eventArgs); if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { & $showDetails } })
$claudeNotifyIcon.Add_MouseClick({ param($sender, $eventArgs); if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { & $showDetails } })
$antigravityNotifyIcon.Add_MouseClick({ param($sender, $eventArgs); if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { & $showDetails } })
$refreshMenu.Add_Click({ Request-FetchNow })
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

$schedulerTimer = New-Object System.Windows.Forms.Timer
$schedulerTimer.Interval = 1000
$schedulerTimer.Add_Tick({ Invoke-FetchScheduler })
$schedulerTimer.Start()

try {
    Start-UsageApiServer
    Update-Snapshot
    Invoke-FetchScheduler
    if ($SmokeTest) {
        Write-Host 'LLM Usage Monitor smoke test passed.'
    } else {
        [System.Windows.Forms.Application]::Run()
    }
} finally {
    $schedulerTimer.Stop(); $schedulerTimer.Dispose()
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
