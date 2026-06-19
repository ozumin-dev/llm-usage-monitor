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
    $dialog.ClientSize = New-Object System.Drawing.Size 420, 390
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.Font = New-Object System.Drawing.Font 'Segoe UI', 9
    $dialog.Tag = $false

    $trayGroup = New-Object System.Windows.Forms.GroupBox
    $trayGroup.Text = 'タスクトレイ'
    $trayGroup.Location = New-Object System.Drawing.Point 12, 12
    $trayGroup.Size = New-Object System.Drawing.Size 396, 90
    $codexCheck = New-Object System.Windows.Forms.CheckBox
    $codexCheck.Text = 'Codexアイコンを表示'
    $codexCheck.Location = New-Object System.Drawing.Point 16, 24
    $codexCheck.Size = New-Object System.Drawing.Size 180, 24
    $codexCheck.Checked = $settings.ShowCodexTrayIcon
    $claudeCheck = New-Object System.Windows.Forms.CheckBox
    $claudeCheck.Text = 'Claudeアイコンを表示'
    $claudeCheck.Location = New-Object System.Drawing.Point 205, 24
    $claudeCheck.Size = New-Object System.Drawing.Size 180, 24
    $claudeCheck.Checked = $settings.ShowClaudeTrayIcon
    $startupCheck = New-Object System.Windows.Forms.CheckBox
    $startupCheck.Text = 'Windowsログイン時に開始'
    $startupCheck.Location = New-Object System.Drawing.Point 16, 54
    $startupCheck.Size = New-Object System.Drawing.Size 220, 24
    $startupCheck.Checked = Test-MonitorStartupEnabled
    $trayGroup.Controls.AddRange(@($codexCheck, $claudeCheck, $startupCheck))

    $updateGroup = New-Object System.Windows.Forms.GroupBox
    $updateGroup.Text = '更新間隔'
    $updateGroup.Location = New-Object System.Drawing.Point 12, 112
    $updateGroup.Size = New-Object System.Drawing.Size 396, 100
    $localLabel = New-Object System.Windows.Forms.Label
    $localLabel.Text = 'ローカル表示・Codex'
    $localLabel.Location = New-Object System.Drawing.Point 16, 28
    $localLabel.Size = New-Object System.Drawing.Size 180, 22
    $localValue = New-Object System.Windows.Forms.NumericUpDown
    $localValue.Location = New-Object System.Drawing.Point 235, 26
    $localValue.Size = New-Object System.Drawing.Size 90, 22
    $localValue.Minimum = 5; $localValue.Maximum = 3600; $localValue.Value = $settings.LocalRefreshSeconds
    $localUnit = New-Object System.Windows.Forms.Label
    $localUnit.Text = '秒'
    $localUnit.Location = New-Object System.Drawing.Point 332, 28
    $claudeLabel = New-Object System.Windows.Forms.Label
    $claudeLabel.Text = 'Claude API'
    $claudeLabel.Location = New-Object System.Drawing.Point 16, 62
    $claudeLabel.Size = New-Object System.Drawing.Size 180, 22
    $claudeValue = New-Object System.Windows.Forms.NumericUpDown
    $claudeValue.Location = New-Object System.Drawing.Point 235, 60
    $claudeValue.Size = New-Object System.Drawing.Size 90, 22
    $claudeValue.Minimum = 5; $claudeValue.Maximum = 3600; $claudeValue.Value = $settings.ClaudeRefreshSeconds
    $claudeUnit = New-Object System.Windows.Forms.Label
    $claudeUnit.Text = '秒'
    $claudeUnit.Location = New-Object System.Drawing.Point 332, 62
    $updateGroup.Controls.AddRange(@($localLabel, $localValue, $localUnit, $claudeLabel, $claudeValue, $claudeUnit))

    $apiGroup = New-Object System.Windows.Forms.GroupBox
    $apiGroup.Text = 'ローカルAPI'
    $apiGroup.Location = New-Object System.Drawing.Point 12, 222
    $apiGroup.Size = New-Object System.Drawing.Size 396, 82
    $apiCheck = New-Object System.Windows.Forms.CheckBox
    $apiCheck.Text = 'APIを有効化（127.0.0.1のみ）'
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
    $note.Text = '両方のアイコンを非表示にするとAPI専用モードになります。設定はスタートメニューから再度開けます。'
    $note.Location = New-Object System.Drawing.Point 14, 314
    $note.Size = New-Object System.Drawing.Size 390, 35
    $note.ForeColor = [System.Drawing.Color]::DimGray

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'キャンセル'
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelButton.Location = New-Object System.Drawing.Point 224, 354
    $cancelButton.Size = New-Object System.Drawing.Size 86, 28
    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = '保存して再起動'
    $saveButton.Location = New-Object System.Drawing.Point 318, 354
    $saveButton.Size = New-Object System.Drawing.Size 90, 28

    $saveButton.Add_Click({
        if (-not $codexCheck.Checked -and -not $claudeCheck.Checked -and -not $apiCheck.Checked) {
            [System.Windows.Forms.MessageBox]::Show('少なくとも1つのトレイアイコン、またはAPIを有効にしてください。', 'LLM Usage Monitor') | Out-Null
            return
        }
        $newSettings = [pscustomobject]@{
            ShowCodexTrayIcon = $codexCheck.Checked
            ShowClaudeTrayIcon = $claudeCheck.Checked
            LocalRefreshSeconds = [int]$localValue.Value
            ClaudeRefreshSeconds = [int]$claudeValue.Value
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
    $dialog.Controls.AddRange(@($trayGroup, $updateGroup, $apiGroup, $note, $cancelButton, $saveButton))
    if (-not $SmokeTest) { [void]$dialog.ShowDialog() }
    $saved = [bool]$dialog.Tag
    $dialog.Dispose()
    return $saved
}
