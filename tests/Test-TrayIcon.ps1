$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName System.Drawing
. (Join-Path $root 'src\TrayIcon.ps1')

function Assert-Color([string]$ExpectedHtml, $Actual, [string]$Message) {
    $expected = [System.Drawing.ColorTranslator]::FromHtml($ExpectedHtml)
    if ($expected.ToArgb() -ne $Actual.ToArgb()) {
        throw "$Message (expected=$ExpectedHtml, actual=$([System.Drawing.ColorTranslator]::ToHtml($Actual)))"
    }
}

Assert-Color '#F04444' (Get-UsageChartColor 'Codex' 99) 'Codex danger color'
Assert-Color '#9B1C1C' (Get-UsageChartColor 'Codex' 100) 'Codex limit color'
Assert-Color '#D97757' (Get-UsageChartColor 'Claude' 50) 'Claude normal color'
Assert-Color '#FFD60A' (Get-UsageChartColor 'Claude' 75) 'Claude warning color'
Assert-Color '#FF3B30' (Get-UsageChartColor 'Claude' 99) 'Claude danger color'
Assert-Color '#9B1C1C' (Get-UsageChartColor 'Claude' 100) 'Claude limit color'
Assert-Color '#F04444' (Get-UsageChartColor 'Antigravity' 99) 'Antigravity danger color'
Assert-Color '#9B1C1C' (Get-UsageChartColor 'Antigravity' 100) 'Antigravity limit color'

# Each provider keeps its own track tint so idle icons stay distinguishable.
$tracks = @('Codex', 'Claude', 'Antigravity') | ForEach-Object { (Get-ProviderTrackColor $_).ToArgb() }
if (@($tracks | Select-Object -Unique).Count -ne 3) { throw 'Provider track colours must differ' }

# Claude's per-model (Fable) gauge fills the corners outside the circle.
$plain = New-ProviderUsageBitmap 'Claude' 50 50 60 32
$scoped = New-ProviderUsageBitmap 'Claude' 50 50 60 32 95
try {
    if ($plain.GetPixel(1, 30).A -ne 0) { throw 'Corner should be transparent without a scoped limit' }
    # Bottom-left corner lies at ~62-75% of the clockwise sweep, so 95% paints it red.
    Assert-Color '#FF3B30' $scoped.GetPixel(1, 30) 'Scoped gauge corner colour'
} finally {
    $plain.Dispose(); $scoped.Dispose()
}

$script:customRendererCalled = $false
function New-CustomProviderUsageIcon {
    param($Provider, $FiveHourUsed, $WeeklyUsed, $FiveHourResetRemainingPercent)
    $script:customRendererCalled = $true
    return New-ProviderUsageIcon $Provider $FiveHourUsed $WeeklyUsed $FiveHourResetRemainingPercent
}
$customIcon = New-MonitorTrayIcon 'Codex' 20 30 40
try {
    if (-not $script:customRendererCalled) { throw 'Custom icon renderer was not called' }
    if ($customIcon -isnot [System.Drawing.Icon]) { throw 'Custom icon renderer did not return an icon' }
} finally {
    if ($null -ne $customIcon) { $customIcon.Dispose() }
    Remove-Item -Path Function:\New-CustomProviderUsageIcon -ErrorAction SilentlyContinue
}

Write-Host 'All TrayIcon tests passed.' -ForegroundColor Green
