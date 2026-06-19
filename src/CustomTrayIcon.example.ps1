# Copy this file to CustomTrayIcon.ps1 in the installed application folder.
# Place codex.ico and/or claude.ico in the adjacent icons folder.
# Return $null to keep using the built-in dynamic usage icon.
function New-CustomProviderUsageIcon {
    [CmdletBinding()]
    param(
        [string]$Provider,
        [Nullable[double]]$FiveHourUsed,
        [Nullable[double]]$WeeklyUsed,
        [Nullable[double]]$FiveHourResetRemainingPercent
    )

    $fileName = '{0}.ico' -f $Provider.ToLowerInvariant()
    $iconPath = Join-Path $PSScriptRoot (Join-Path 'icons' $fileName)
    if (-not (Test-Path -LiteralPath $iconPath)) { return $null }

    $sourceIcon = New-Object System.Drawing.Icon $iconPath
    try {
        return [System.Drawing.Icon]$sourceIcon.Clone()
    } finally {
        $sourceIcon.Dispose()
    }
}
