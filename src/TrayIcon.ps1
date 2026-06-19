Set-StrictMode -Version 2.0

if (-not ('LLMUsageMonitor.NativeIconMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace LLMUsageMonitor {
    public static class NativeIconMethods {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool DestroyIcon(IntPtr handle);
    }
}
'@
}

function Get-ProviderBaseColor {
    param([ValidateSet('Codex', 'Claude')][string]$Provider)
    if ($Provider -eq 'Codex') { return [System.Drawing.ColorTranslator]::FromHtml('#19BCE4') }
    return [System.Drawing.ColorTranslator]::FromHtml('#D97757')
}

function Get-UsageChartColor {
    param(
        [ValidateSet('Codex', 'Claude')][string]$Provider,
        [Nullable[double]]$UsedPercent
    )
    if ($null -eq $UsedPercent) { return [System.Drawing.Color]::FromArgb(135, 145, 155) }

    if ($Provider -eq 'Codex') {
        if ($UsedPercent -ge 90) { return [System.Drawing.ColorTranslator]::FromHtml('#F04444') }
        if ($UsedPercent -ge 70) { return [System.Drawing.ColorTranslator]::FromHtml('#FFB000') }
        return [System.Drawing.ColorTranslator]::FromHtml('#32C7F0')
    }

    if ($UsedPercent -ge 90) { return [System.Drawing.ColorTranslator]::FromHtml('#C026D3') }
    if ($UsedPercent -ge 70) { return [System.Drawing.ColorTranslator]::FromHtml('#FF7A00') }
    return [System.Drawing.ColorTranslator]::FromHtml('#D97757')
}

function New-ProviderUsageBitmap {
    param(
        [ValidateSet('Codex', 'Claude')][string]$Provider,
        [Nullable[double]]$FiveHourUsed,
        [Nullable[double]]$WeeklyUsed,
        [Nullable[double]]$FiveHourResetRemainingPercent = $null,
        [int]$Size = 32
    )

    $bitmap = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

    $scale = $Size / 32.0
    $base = Get-ProviderBaseColor $Provider
    $track = if ($Provider -eq 'Codex') {
        [System.Drawing.ColorTranslator]::FromHtml('#183B47')
    } else {
        [System.Drawing.ColorTranslator]::FromHtml('#4A2E27')
    }

    # Keep the usage ring inside the reset-time markers so both remain legible
    # after Windows scales the tray icon down to 16 px.
    $outerRect = New-Object System.Drawing.RectangleF (6 * $scale), (6 * $scale), (20 * $scale), (20 * $scale)
    $trackPen = New-Object System.Drawing.Pen $track, (4.6 * $scale)
    $trackPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $trackPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $graphics.DrawEllipse($trackPen, $outerRect)

    if ($null -ne $FiveHourUsed) {
        $five = [Math]::Max(0, [Math]::Min(100, [double]$FiveHourUsed))
        $fivePen = New-Object System.Drawing.Pen (Get-UsageChartColor $Provider $five), (4.6 * $scale)
        $fivePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $fivePen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        if ($five -ge 99.95) {
            $graphics.DrawEllipse($fivePen, $outerRect)
        } elseif ($five -gt 0) {
            $graphics.DrawArc($fivePen, $outerRect, -90, [single](3.6 * $five))
        }
        $fivePen.Dispose()
    }

    $identityRect = New-Object System.Drawing.RectangleF (1.8 * $scale), (1.8 * $scale), (28.4 * $scale), (28.4 * $scale)
    $resetTrackColor = if ($null -eq $FiveHourResetRemainingPercent) {
        [System.Drawing.Color]::FromArgb(120, 130, 140)
    } else {
        $base
    }
    $resetTrackPen = New-Object System.Drawing.Pen $resetTrackColor, (2.4 * $scale)
    $resetTrackPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $resetTrackPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    for ($segment = 0; $segment -lt 5; $segment++) {
        $graphics.DrawArc($resetTrackPen, $identityRect, [single](-86 + (72 * $segment)), 52)
    }
    if ($null -ne $FiveHourResetRemainingPercent) {
        $remaining = [Math]::Max(0, [Math]::Min(100, [double]$FiveHourResetRemainingPercent))
        $activeSegments = [Math]::Min(5, [Math]::Ceiling($remaining / 20))
        $resetPen = New-Object System.Drawing.Pen ([System.Drawing.ColorTranslator]::FromHtml('#F8FAFC')), (3.2 * $scale)
        $resetPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $resetPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        for ($segment = 0; $segment -lt $activeSegments; $segment++) {
            $graphics.DrawArc($resetPen, $identityRect, [single](-86 + (72 * $segment)), 52)
        }
        $resetPen.Dispose()
    }

    $innerRect = New-Object System.Drawing.RectangleF (10 * $scale), (10 * $scale), (12 * $scale), (12 * $scale)
    $innerTrackBrush = New-Object System.Drawing.SolidBrush $track
    $graphics.FillEllipse($innerTrackBrush, $innerRect)
    if ($null -ne $WeeklyUsed) {
        $week = [Math]::Max(0, [Math]::Min(100, [double]$WeeklyUsed))
        $weekBrush = New-Object System.Drawing.SolidBrush (Get-UsageChartColor $Provider $week)
        if ($week -ge 99.95) {
            $graphics.FillEllipse($weekBrush, $innerRect)
        } elseif ($week -gt 0) {
            $graphics.FillPie($weekBrush, $innerRect.X, $innerRect.Y, $innerRect.Width, $innerRect.Height, -90, [single](3.6 * $week))
        }
        $weekBrush.Dispose()
    }
    $innerPen = New-Object System.Drawing.Pen $base, (1.4 * $scale)
    $graphics.DrawEllipse($innerPen, $innerRect)

    $innerPen.Dispose(); $innerTrackBrush.Dispose(); $resetTrackPen.Dispose(); $trackPen.Dispose(); $graphics.Dispose()
    return $bitmap
}

function New-ProviderUsageIcon {
    param(
        [ValidateSet('Codex', 'Claude')][string]$Provider,
        [Nullable[double]]$FiveHourUsed,
        [Nullable[double]]$WeeklyUsed,
        [Nullable[double]]$FiveHourResetRemainingPercent = $null
    )
    $bitmap = New-ProviderUsageBitmap $Provider $FiveHourUsed $WeeklyUsed $FiveHourResetRemainingPercent 32
    $handle = $bitmap.GetHicon()
    try {
        return [System.Drawing.Icon]::FromHandle($handle).Clone()
    } finally {
        [LLMUsageMonitor.NativeIconMethods]::DestroyIcon($handle) | Out-Null
        $bitmap.Dispose()
    }
}
