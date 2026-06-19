Set-StrictMode -Version 2.0

function ConvertTo-NullableDouble {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    try { return [double]$Value } catch { return $null }
}

function ConvertTo-NullableInt64 {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    try { return [int64]$Value } catch { return $null }
}

function Get-ObjectProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function New-UsageWindow {
    param($Window)

    if ($null -eq $Window) { return $null }
    $used = ConvertTo-NullableDouble (Get-ObjectProperty $Window 'used_percent')
    $usedPercentage = Get-ObjectProperty $Window 'used_percentage'
    if ($null -eq $used -and $null -ne $usedPercentage) {
        $used = ConvertTo-NullableDouble $usedPercentage
    }
    if ($null -eq $used) { return $null }

    $reset = ConvertTo-NullableInt64 (Get-ObjectProperty $Window 'resets_at')
    if ($null -eq $reset) { $reset = ConvertTo-NullableInt64 (Get-ObjectProperty $Window 'resets_at_epoch') }

    [pscustomobject]@{
        UsedPercent = [Math]::Max(0, [Math]::Min(100, $used))
        LeftPercent = [Math]::Max(0, [Math]::Min(100, 100 - $used))
        ResetsAtEpoch = $reset
        WindowMinutes = ConvertTo-NullableInt64 (Get-ObjectProperty $Window 'window_minutes')
    }
}

function Get-CodexUsage {
    [CmdletBinding()]
    param(
        [string[]]$SearchRoots = @(
            (Join-Path $HOME '.codex\sessions'),
            (Join-Path $HOME '.codex\archived_sessions')
        ),
        [int]$FilesToInspect = 20,
        [int]$TailLines = 1000
    )

    $files = @()
    foreach ($root in $SearchRoots) {
        if (Test-Path -LiteralPath $root) {
            $files += Get-ChildItem -LiteralPath $root -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue
        }
    }

    $files = @($files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $FilesToInspect)
    foreach ($file in $files) {
        $lines = @(Get-Content -LiteralPath $file.FullName -Tail $TailLines -ErrorAction SilentlyContinue)
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            try { $event = $lines[$i] | ConvertFrom-Json -ErrorAction Stop } catch { continue }

            $limits = $null
            $payload = Get-ObjectProperty $event 'payload'
            if ($null -ne $payload) {
                $limits = Get-ObjectProperty $payload 'rate_limits'
                $info = Get-ObjectProperty $payload 'info'
                if ($null -eq $limits -and $null -ne $info) {
                    $limits = Get-ObjectProperty $info 'rate_limits'
                }
            }
            if ($null -eq $limits) { continue }

            $capturedAt = $null
            try { $capturedAt = [DateTimeOffset]::Parse((Get-ObjectProperty $event 'timestamp')) } catch {
                $capturedAt = [DateTimeOffset]$file.LastWriteTime
            }

            return [pscustomobject]@{
                Provider = 'Codex'
                Model = $null
                Plan = Get-ObjectProperty $limits 'plan_type'
                FiveHour = New-UsageWindow (Get-ObjectProperty $limits 'primary')
                Weekly = New-UsageWindow (Get-ObjectProperty $limits 'secondary')
                ContextUsedPercent = $null
                CapturedAt = $capturedAt
                Source = 'codex_session_events'
            }
        }
    }

    return $null
}

function Get-ClaudeUsage {
    [CmdletBinding()]
    param(
        [Alias('Path')]
        [string[]]$Paths = @(
            (Join-Path $HOME '.ai-usage\claude-desktop-usage.json'),
            (Join-Path $HOME '.ai-usage\claude-code-usage.json')
        )
    )

    $selectedPath = $Paths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $selectedPath) { return $null }
    try {
        $data = Get-Content -Raw -LiteralPath $selectedPath | ConvertFrom-Json -ErrorAction Stop
        $capturedAt = [DateTimeOffset]::Parse((Get-ObjectProperty $data 'captured_at'))
    } catch {
        return $null
    }

    [pscustomobject]@{
        Provider = 'Claude Code'
        Model = Get-ObjectProperty $data 'model'
        Plan = $null
        FiveHour = New-UsageWindow (Get-ObjectProperty $data 'five_hour')
        Weekly = New-UsageWindow (Get-ObjectProperty $data 'weekly')
        ContextUsedPercent = if ($null -ne (Get-ObjectProperty $data 'context_window')) {
            ConvertTo-NullableDouble (Get-ObjectProperty (Get-ObjectProperty $data 'context_window') 'used_percent')
        } else { $null }
        CapturedAt = $capturedAt
        Source = 'claude_code_statusline'
    }
}

function Get-UsageSnapshot {
    [pscustomobject]@{
        Codex = Get-CodexUsage
        Claude = Get-ClaudeUsage
        ReadAt = [DateTimeOffset]::Now
    }
}

function Test-UsageWindowExpired {
    param($Window, [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    if ($null -eq $Window -or $null -eq $Window.ResetsAtEpoch) { return $false }
    return $Window.ResetsAtEpoch -le $Now.ToUnixTimeSeconds()
}

function Format-ResetTime {
    param($Window, [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    if ($null -eq $Window -or $null -eq $Window.ResetsAtEpoch) { return '更新時刻不明' }

    $reset = [DateTimeOffset]::FromUnixTimeSeconds([int64]$Window.ResetsAtEpoch).ToLocalTime()
    if ($reset -le $Now) { return '期限経過（次回利用時に更新）' }
    $remaining = $reset - $Now
    if ($remaining.TotalDays -ge 1) {
        return ('{0:M/d H:mm}（あと{1}日{2}時間）' -f $reset, [Math]::Floor($remaining.TotalDays), $remaining.Hours)
    }
    return ('{0:H:mm}（あと{1}時間{2}分）' -f $reset, [Math]::Floor($remaining.TotalHours), $remaining.Minutes)
}

function Format-CapturedAt {
    param($Usage, [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    if ($null -eq $Usage) { return 'データなし' }
    $age = $Now - $Usage.CapturedAt
    if ($age.TotalMinutes -lt 2) { return 'たった今' }
    if ($age.TotalHours -lt 1) { return ('{0}分前' -f [Math]::Floor($age.TotalMinutes)) }
    if ($age.TotalDays -lt 1) { return ('{0}時間前' -f [Math]::Floor($age.TotalHours)) }
    return $Usage.CapturedAt.ToLocalTime().ToString('M/d H:mm')
}

function Get-MaxActiveUsage {
    param($Snapshot)
    $values = @()
    foreach ($usage in @($Snapshot.Codex, $Snapshot.Claude)) {
        if ($null -eq $usage) { continue }
        foreach ($window in @($usage.FiveHour, $usage.Weekly)) {
            if ($null -ne $window -and -not (Test-UsageWindowExpired $window)) {
                $values += [double]$window.UsedPercent
            }
        }
    }
    if ($values.Count -eq 0) { return $null }
    return ($values | Measure-Object -Maximum).Maximum
}
