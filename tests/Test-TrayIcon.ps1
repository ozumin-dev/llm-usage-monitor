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
Assert-Color '#4B5563' (Get-UsageChartColor 'Codex' 100) 'Codex limit color'
Assert-Color '#C026D3' (Get-UsageChartColor 'Claude' 99) 'Claude danger color'
Assert-Color '#4B5563' (Get-UsageChartColor 'Claude' 100) 'Claude limit color'

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
