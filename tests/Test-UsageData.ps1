$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\UsageData.ps1')

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) {
        throw "$Message (expected=$Expected, actual=$Actual)"
    }
}

$fixtureDir = Join-Path $PSScriptRoot 'fixtures'
$codex = Get-CodexUsage -SearchRoots @($fixtureDir) -FilesToInspect 5 -TailLines 50
Assert-Equal 'Codex' $codex.Provider 'Codex provider'
Assert-Equal 22 $codex.FiveHour.UsedPercent 'Codex 5h used percent'
Assert-Equal 78 $codex.FiveHour.LeftPercent 'Codex 5h left percent'
Assert-Equal 39 $codex.Weekly.UsedPercent 'Codex weekly used percent'
Assert-Equal 'plus' $codex.Plan 'Codex plan'

$claude = Get-ClaudeUsage -Path (Join-Path $fixtureDir 'claude-code-usage.json')
Assert-Equal 'Claude Code' $claude.Provider 'Claude provider'
Assert-Equal 'Opus Test' $claude.Model 'Claude model'
Assert-Equal 20 $claude.FiveHour.UsedPercent 'Claude 5h used percent'
Assert-Equal 93 $claude.Weekly.UsedPercent 'Claude weekly used percent'
Assert-Equal 71 $claude.ContextUsedPercent 'Claude context percent'

$missing = Get-ClaudeUsage -Path (Join-Path $fixtureDir 'missing.json')
Assert-Equal $null $missing 'Missing Claude data'

$resetTestNow = [DateTimeOffset]::FromUnixTimeSeconds(100000)
$halfWindow = [pscustomobject]@{ ResetsAtEpoch = 109000; WindowMinutes = 300 }
$expiredWindow = [pscustomobject]@{ ResetsAtEpoch = 99999; WindowMinutes = 300 }
$unknownResetWindow = [pscustomobject]@{ ResetsAtEpoch = $null; WindowMinutes = 300 }
Assert-Equal 50 (Get-UsageWindowRemainingPercent $halfWindow $resetTestNow) '5h reset remaining percent'
Assert-Equal 0 (Get-UsageWindowRemainingPercent $expiredWindow $resetTestNow) 'Expired reset remaining percent'
Assert-Equal $null (Get-UsageWindowRemainingPercent $unknownResetWindow $resetTestNow) 'Unknown reset remaining percent'

$snapshotPath = Join-Path $env:TEMP ('llm-usage-test-{0}.json' -f $PID)
try {
    $snapshot = [pscustomobject]@{ Codex = $codex; Claude = $claude; ReadAt = [DateTimeOffset]::Now }
    Save-UsageSnapshot -Snapshot $snapshot -Path $snapshotPath
    $apiData = Get-Content -Raw -LiteralPath $snapshotPath | ConvertFrom-Json
    Assert-Equal 1 $apiData.schema_version 'API schema version'
    Assert-Equal $true $apiData.providers.codex.available 'API Codex availability'
    Assert-Equal 22 $apiData.providers.codex.five_hour.used_percent 'API Codex 5h percent'
    Assert-Equal 93 $apiData.providers.claude.weekly.used_percent 'API Claude weekly percent'
} finally {
    if (Test-Path -LiteralPath $snapshotPath) { Remove-Item -LiteralPath $snapshotPath -Force }
}

Write-Host 'All UsageData tests passed.' -ForegroundColor Green
