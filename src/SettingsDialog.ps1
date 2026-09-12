function New-ProviderSettingsGroup {
    # One row per provider: fetch on/off, tray icon, fetch interval.
    param($Dialog, [string]$Title, [int]$Top, [bool]$Enabled, [bool]$ShowIcon, [int]$Seconds, [int]$MinSeconds)
    $group = New-Object System.Windows.Forms.GroupBox
    $group.Text = $Title
    $group.Location = New-Object System.Drawing.Point 12, $Top
    $group.Size = New-Object System.Drawing.Size 396, 56

    $enabledCheck = New-Object System.Windows.Forms.CheckBox
    $enabledCheck.Text = '取得する'
    $enabledCheck.Location = New-Object System.Drawing.Point 16, 22
    $enabledCheck.Size = New-Object System.Drawing.Size 90, 24
    $enabledCheck.Checked = $Enabled
    $iconCheck = New-Object System.Windows.Forms.CheckBox
    $iconCheck.Text = 'トレイに表示'
    $iconCheck.Location = New-Object System.Drawing.Point 108, 22
    $iconCheck.Size = New-Object System.Drawing.Size 112, 24
    $iconCheck.Checked = $ShowIcon
    $intervalLabel = New-Object System.Windows.Forms.Label
    $intervalLabel.Text = '取得間隔'
    $intervalLabel.Location = New-Object System.Drawing.Point 226, 25
    $intervalLabel.Size = New-Object System.Drawing.Size 64, 20
    $intervalValue = New-Object System.Windows.Forms.NumericUpDown
    $intervalValue.Location = New-Object System.Drawing.Point 292, 22
    $intervalValue.Size = New-Object System.Drawing.Size 70, 22
    $intervalValue.Minimum = $MinSeconds; $intervalValue.Maximum = 3600
    $intervalValue.Value = [Math]::Max($MinSeconds, [Math]::Min(3600, $Seconds))
    $unit = New-Object System.Windows.Forms.Label
    $unit.Text = '秒'
    $unit.Location = New-Object System.Drawing.Point 366, 25
    $unit.Size = New-Object System.Drawing.Size 24, 20

    $sync = { $iconCheck.Enabled = $enabledCheck.Checked; $intervalValue.Enabled = $enabledCheck.Checked }.GetNewClosure()
    $enabledCheck.Add_CheckedChanged($sync)
    & $sync

    $group.Controls.AddRange(@($enabledCheck, $iconCheck, $intervalLabel, $intervalValue, $unit))
    $Dialog.Controls.Add($group)
    return @{ Enabled = $enabledCheck; ShowIcon = $iconCheck; Interval = $intervalValue }
}

function Show-MonitorSettingsDialog {
    [CmdletBinding()]
    param(
        [string]$MonitorScript,
        [string]$SettingsPath = (Get-MonitorSettingsPath),
        [switch]$SmokeTest
    )

    $settings = Get-MonitorSettings -Path $SettingsPath
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'LLM Usage Monitor Settings'
    $dialog.ClientSize = New-Object System.Drawing.Size 420, 440
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.Font = New-Object System.Drawing.Font 'Segoe UI', 9
    $dialog.Tag = $false

    $codex = New-ProviderSettingsGroup $dialog 'Codex' 12 $settings.CodexEnabled $settings.ShowCodexTrayIcon $settings.CodexRefreshSeconds 60
    $claude = New-ProviderSettingsGroup $dialog 'Claude' 76 $settings.ClaudeEnabled $settings.ShowClaudeTrayIcon $settings.ClaudeRefreshSeconds 30
    $antigravity = New-ProviderSettingsGroup $dialog 'Antigravity (agy)' 140 $settings.AntigravityEnabled $settings.ShowAntigravityTrayIcon $settings.AntigravityRefreshSeconds 60

    $generalGroup = New-Object System.Windows.Forms.GroupBox
    $generalGroup.Text = '全般'
    $generalGroup.Location = New-Object System.Drawing.Point 12, 204
    $generalGroup.Size = New-Object System.Drawing.Size 396, 56
    $startupCheck = New-Object System.Windows.Forms.CheckBox
    $startupCheck.Text = 'Windowsログイン時に開始'
    $startupCheck.Location = New-Object System.Drawing.Point 16, 22
    $startupCheck.Size = New-Object System.Drawing.Size 180, 24
    $startupCheck.Checked = Test-MonitorStartupEnabled
    $alertsCheck = New-Object System.Windows.Forms.CheckBox
    $alertsCheck.Text = '80%･95%到達時に通知'
    $alertsCheck.Location = New-Object System.Drawing.Point 205, 22
    $alertsCheck.Size = New-Object System.Drawing.Size 180, 24
    $alertsCheck.Checked = $settings.UsageAlertsEnabled
    $generalGroup.Controls.AddRange(@($startupCheck, $alertsCheck))

    $apiGroup = New-Object System.Windows.Forms.GroupBox
    $apiGroup.Text = 'ローカルAPI'
    $apiGroup.Location = New-Object System.Drawing.Point 12, 268
    $apiGroup.Size = New-Object System.Drawing.Size 396, 82
    $apiCheck = New-Object System.Windows.Forms.CheckBox
    $apiCheck.Text = 'APIを有効化 (127.0.0.1のみ)'
    $apiCheck.Location = New-Object System.Drawing.Point 16, 22
    $apiCheck.Size = New-Object System.Drawing.Size 240, 24
    $apiCheck.Checked = $settings.ApiEnabled
    $portLabel = New-Object System.Windows.Forms.Label
    $portLabel.Text = 'ポート'
    $portLabel.Location = New-Object System.Drawing.Point 16, 52
    $portLabel.Size = New-Object System.Drawing.Size 80, 22
    $portValue = New-Object System.Windows.Forms.NumericUpDown
    $portValue.Location = New-Object System.Drawing.Point 235, 50
    $portValue.Size = New-Object System.Drawing.Size 90, 22
    $portValue.Minimum = 1024; $portValue.Maximum = 65535; $portValue.Value = $settings.ApiPort
    $portValue.Enabled = $settings.ApiEnabled
    $apiCheck.Add_CheckedChanged({ $portValue.Enabled = $apiCheck.Checked })
    $apiGroup.Controls.AddRange(@($apiCheck, $portLabel, $portValue))

    $note = New-Object System.Windows.Forms.Label
    $note.Text = '取得しないサービスはトレイにも出ません｡すべてのアイコンを非表示にするとAPI専用モードになります(設定はスタートメニューから開けます)｡'
    $note.Location = New-Object System.Drawing.Point 14, 358
    $note.Size = New-Object System.Drawing.Size 394, 36
    $note.ForeColor = [System.Drawing.Color]::DimGray

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'キャンセル'
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelButton.Location = New-Object System.Drawing.Point 204, 402
    $cancelButton.Size = New-Object System.Drawing.Size 86, 28
    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = '保存して再起動'
    $saveButton.Location = New-Object System.Drawing.Point 298, 402
    $saveButton.Size = New-Object System.Drawing.Size 110, 28

    $saveButton.Add_Click({
        $anyIcon = @($codex, $claude, $antigravity) | Where-Object { $_.Enabled.Checked -and $_.ShowIcon.Checked }
        if (@($anyIcon).Count -eq 0 -and -not $apiCheck.Checked) {
            [System.Windows.Forms.MessageBox]::Show('少なくとも1つのトレイアイコンか､APIを有効にしてください｡', 'LLM Usage Monitor') | Out-Null
            return
        }
        $newSettings = [pscustomobject]@{
            CodexEnabled = $codex.Enabled.Checked
            ClaudeEnabled = $claude.Enabled.Checked
            AntigravityEnabled = $antigravity.Enabled.Checked
            ShowCodexTrayIcon = $codex.ShowIcon.Checked
            ShowClaudeTrayIcon = $claude.ShowIcon.Checked
            ShowAntigravityTrayIcon = $antigravity.ShowIcon.Checked
            LocalRefreshSeconds = $settings.LocalRefreshSeconds
            CodexRefreshSeconds = [int]$codex.Interval.Value
            ClaudeRefreshSeconds = [int]$claude.Interval.Value
            AntigravityRefreshSeconds = [int]$antigravity.Interval.Value
            UsageAlertsEnabled = $alertsCheck.Checked
            ApiEnabled = $apiCheck.Checked
            ApiPort = [int]$portValue.Value
        }
        Save-MonitorSettings -Settings $newSettings -Path $SettingsPath
        Set-MonitorStartupEnabled -Enabled $startupCheck.Checked -MonitorScript $MonitorScript
        $dialog.Tag = $true
        $dialog.Close()
    })

    $dialog.AcceptButton = $saveButton
    $dialog.CancelButton = $cancelButton
    $dialog.Controls.AddRange(@($generalGroup, $apiGroup, $note, $cancelButton, $saveButton))
    if (-not $SmokeTest) { [void]$dialog.ShowDialog() }
    $saved = [bool]$dialog.Tag
    $dialog.Dispose()
    return $saved
}
