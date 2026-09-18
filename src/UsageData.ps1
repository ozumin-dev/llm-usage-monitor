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
        [string]$Path = (Join-Path $HOME '.ai-usage\codex-usage.json'),
        [int]$MaxAgeSeconds = 900
    )

    # Primary: the official app-server rate limits written by codex-usage.py
    # (live, authoritative, and carries the account's reset credits). Fall back
    # to scraping session events only if that file is missing or stale.
    if (Test-Path -LiteralPath $Path) {
        try {
            $data = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -ErrorAction Stop
            $capturedAt = [DateTimeOffset]::Parse((Get-ObjectProperty $data 'captured_at'))
            if (([DateTimeOffset]::Now - $capturedAt).TotalSeconds -le $MaxAgeSeconds) {
                return [pscustomobject]@{
                    Provider = 'Codex'
                    Model = $null
                    Plan = Get-ObjectProperty $data 'plan'
                    FiveHour = New-UsageWindow (Get-ObjectProperty $data 'five_hour')
                    Weekly = New-UsageWindow (Get-ObjectProperty $data 'weekly')
                    ContextUsedPercent = $null
                    ResetCredits = Get-ObjectProperty $data 'reset_credits'
                    CapturedAt = $capturedAt
                    Source = 'codex_app_server_ratelimits'
                }
            }
        } catch {
            # fall through to the session scrape
        }
    }

    return Get-CodexUsageFromSessions
}

function Get-AntigravityUsage {
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path $HOME '.ai-usage\agy-usage.json'),
        [int]$MaxAgeSeconds = 3600
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $data = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -ErrorAction Stop
        $capturedAt = [DateTimeOffset]::Parse((Get-ObjectProperty $data 'captured_at'))
    } catch {
        return $null
    }
    if (([DateTimeOffset]::Now - $capturedAt).TotalSeconds -gt $MaxAgeSeconds) { return $null }

    # Parsed per-family windows for the GUI; the raw families object is what the
    # API exposes.
    $families = Get-ObjectProperty $data 'families'
    $familyUsages = @()
    if ($null -ne $families) {
        foreach ($property in $families.PSObject.Properties) {
            $familyUsages += [pscustomobject]@{
                Key = $property.Name
                Label = Get-ObjectProperty $property.Value 'label'
                FiveHour = New-UsageWindow (Get-ObjectProperty $property.Value 'five_hour')
                Weekly = New-UsageWindow (Get-ObjectProperty $property.Value 'weekly')
            }
        }
    }

    [pscustomobject]@{
        Provider = 'Antigravity'
        Model = Get-ObjectProperty $data 'model'
        Plan = $null
        FiveHour = New-UsageWindow (Get-ObjectProperty $data 'five_hour')
        Weekly = New-UsageWindow (Get-ObjectProperty $data 'weekly')
        ContextUsedPercent = $null
        Families = $families
        FamilyUsages = $familyUsages
        CapturedAt = $capturedAt
        Source = 'agy_usage_report'
    }
}

function Get-CodexUsageFromSessions {
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
        Fable = New-UsageWindow (Get-ObjectProperty $data 'fable')
        ContextUsedPercent = if ($null -ne (Get-ObjectProperty $data 'context_window')) {
            ConvertTo-NullableDouble (Get-ObjectProperty (Get-ObjectProperty $data 'context_window') 'used_percent')
        } else { $null }
        CapturedAt = $capturedAt
        Source = 'claude_code_statusline'
    }
}

function Get-ProviderFetchError {
    # The helpers leave <output>.error.json while fetching keeps failing and
    # delete it on the next success, so its presence means "currently failing".
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    # The helpers write UTF-8 (hints are Japanese); PowerShell 5.1 would read ANSI.
    try { $data = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    $message = Get-ObjectProperty $data 'message'
    if (-not $message) { return $null }
    $since = $null
    $lastAt = $null
    try { $since = [DateTimeOffset]::Parse((Get-ObjectProperty $data 'since')) } catch { }
    try { $lastAt = [DateTimeOffset]::Parse((Get-ObjectProperty $data 'last_at')) } catch { }
    [pscustomobject]@{
        Message = [string]$message
        Hint = Get-ObjectProperty $data 'hint'
        Since = $since
        LastAt = $lastAt
        Count = ConvertTo-NullableInt64 (Get-ObjectProperty $data 'count')
    }
}

function New-ProviderFetchError {
    # Same shape as Get-ProviderFetchError, for failures the monitor sees itself
    # (helper missing, python missing, helper crashed before writing its file).
    param([string]$Message, $Previous = $null)
    $now = [DateTimeOffset]::Now
    $since = $now
    $count = 1
    if ($null -ne $Previous -and $Previous.Message -eq $Message) {
        if ($null -ne $Previous.Since) { $since = $Previous.Since }
        if ($null -ne $Previous.Count) { $count = $Previous.Count + 1 }
    }
    [pscustomobject]@{ Message = $Message; Hint = $null; Since = $since; LastAt = $now; Count = $count }
}

$script:ProviderErrorFiles = @{
    Codex = 'codex-usage.error.json'
    Claude = 'claude-desktop-usage.error.json'
    Antigravity = 'agy-usage.error.json'
}

function Get-UsageSnapshot {
    # Providers listed in -Disabled are not read at all (not even the Codex
    # session-scrape fallback) and are reported as disabled. -MonitorErrors
    # holds failures seen by the monitor itself; a helper's error file wins.
    param(
        [string[]]$Disabled = @(),
        [hashtable]$MonitorErrors = @{},
        [string]$DataDirectory = (Join-Path $HOME '.ai-usage')
    )
    $errors = @{}
    foreach ($name in $script:ProviderErrorFiles.Keys) {
        if ($Disabled -contains $name) { continue }
        $fetchError = Get-ProviderFetchError (Join-Path $DataDirectory $script:ProviderErrorFiles[$name])
        if ($null -eq $fetchError -and $MonitorErrors.ContainsKey($name)) { $fetchError = $MonitorErrors[$name] }
        if ($null -ne $fetchError) { $errors[$name] = $fetchError }
    }
    [pscustomobject]@{
        Codex = if ($Disabled -contains 'Codex') { $null } else { Get-CodexUsage }
        Claude = if ($Disabled -contains 'Claude') { $null } else { Get-ClaudeUsage }
        Antigravity = if ($Disabled -contains 'Antigravity') { $null } else { Get-AntigravityUsage }
        Errors = $errors
        Disabled = @($Disabled)
        ReadAt = [DateTimeOffset]::Now
    }
}

function Get-SnapshotError {
    param($Snapshot, [string]$Provider)
    $errors = Get-ObjectProperty $Snapshot 'Errors'
    if ($null -eq $errors -or -not $errors.ContainsKey($Provider)) { return $null }
    return $errors[$Provider]
}

function ConvertTo-ApiUsageWindow {
    param($Window, [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    if ($null -eq $Window) { return $null }

    $resetIso = $null
    if ($null -ne $Window.ResetsAtEpoch) {
        $resetIso = [DateTimeOffset]::FromUnixTimeSeconds([int64]$Window.ResetsAtEpoch).ToLocalTime().ToString('o')
    }
    return [ordered]@{
        used_percent = [Math]::Round([double]$Window.UsedPercent, 2)
        left_percent = [Math]::Round([double]$Window.LeftPercent, 2)
        resets_at_epoch = $Window.ResetsAtEpoch
        resets_at = $resetIso
        expired = Test-UsageWindowExpired $Window $Now
    }
}

function ConvertTo-ApiFetchError {
    param($FetchError)
    [ordered]@{
        message = $FetchError.Message
        hint = $FetchError.Hint
        since = if ($null -ne $FetchError.Since) { $FetchError.Since.ToString('o') } else { $null }
        last_at = if ($null -ne $FetchError.LastAt) { $FetchError.LastAt.ToString('o') } else { $null }
        count = $FetchError.Count
    }
}

function ConvertTo-ApiProviderUsage {
    # With -FetchError the provider carries an `error` block; any usage data
    # alongside it is the last successful fetch (see captured_at).
    param($Usage, [DateTimeOffset]$Now = [DateTimeOffset]::Now, [switch]$Disabled, $FetchError = $null)
    if ($Disabled) {
        return [ordered]@{ available = $false; disabled = $true }
    }
    if ($null -eq $Usage) {
        $empty = [ordered]@{ available = $false }
        if ($null -ne $FetchError) { $empty['error'] = ConvertTo-ApiFetchError $FetchError }
        return $empty
    }
    $result = [ordered]@{
        available = $true
        model = $Usage.Model
        plan = $Usage.Plan
        five_hour = ConvertTo-ApiUsageWindow $Usage.FiveHour $Now
        weekly = ConvertTo-ApiUsageWindow $Usage.Weekly $Now
        context_window = if ($null -ne $Usage.ContextUsedPercent) {
            [ordered]@{ used_percent = [Math]::Round([double]$Usage.ContextUsedPercent, 2) }
        } else { $null }
        source = $Usage.Source
        captured_at = $Usage.CapturedAt.ToString('o')
    }
    # Provider-specific extras: Claude Fable cap, Codex reset credits,
    # Antigravity quota families.
    $fable = Get-ObjectProperty $Usage 'Fable'
    if ($null -ne $fable) { $result['fable'] = ConvertTo-ApiUsageWindow $fable $Now }
    $credits = Get-ObjectProperty $Usage 'ResetCredits'
    if ($null -ne $credits) { $result['reset_credits'] = $credits }
    $families = Get-ObjectProperty $Usage 'Families'
    if ($null -ne $families) { $result['families'] = $families }
    if ($null -ne $FetchError) { $result['error'] = ConvertTo-ApiFetchError $FetchError }
    return $result
}

function Save-UsageSnapshot {
    [CmdletBinding()]
    param(
        $Snapshot,
        [string]$Path = (Join-Path $HOME '.ai-usage\usage.json')
    )
    if ($null -eq $Snapshot) { return }

    $now = [DateTimeOffset]::Now
    $disabled = @(Get-ObjectProperty $Snapshot 'Disabled')
    $result = [ordered]@{
        schema_version = 1
        observed_at = $now.ToString('o')
        providers = [ordered]@{
            codex = ConvertTo-ApiProviderUsage $Snapshot.Codex $now -Disabled:($disabled -contains 'Codex') -FetchError (Get-SnapshotError $Snapshot 'Codex')
            claude = ConvertTo-ApiProviderUsage $Snapshot.Claude $now -Disabled:($disabled -contains 'Claude') -FetchError (Get-SnapshotError $Snapshot 'Claude')
            antigravity = ConvertTo-ApiProviderUsage (Get-ObjectProperty $Snapshot 'Antigravity') $now -Disabled:($disabled -contains 'Antigravity') -FetchError (Get-SnapshotError $Snapshot 'Antigravity')
        }
    }

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporary = Join-Path $directory ('.usage.{0}.tmp' -f $PID)
    $json = $result | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($temporary, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Test-UsageWindowExpired {
    param($Window, [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    if ($null -eq $Window -or $null -eq $Window.ResetsAtEpoch) { return $false }
    return $Window.ResetsAtEpoch -le $Now.ToUnixTimeSeconds()
}

function Get-UsageWindowRemainingPercent {
    param(
        $Window,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now,
        [int]$DefaultWindowMinutes = 300
    )
    if ($null -eq $Window -or $null -eq $Window.ResetsAtEpoch) { return $null }
    $windowMinutes = if ($null -ne $Window.WindowMinutes -and [int64]$Window.WindowMinutes -gt 0) {
        [double]$Window.WindowMinutes
    } else {
        [double]$DefaultWindowMinutes
    }
    if ($windowMinutes -le 0) { return $null }
    $remainingSeconds = [double]$Window.ResetsAtEpoch - $Now.ToUnixTimeSeconds()
    return [Math]::Max(0, [Math]::Min(100, ($remainingSeconds / ($windowMinutes * 60)) * 100))
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
