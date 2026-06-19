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
        [double]$UpdateRemainingPercent = 100,
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

    $outerRect = New-Object System.Drawing.RectangleF (3 * $scale), (3 * $scale), (26 * $scale), (26 * $scale)
    $trackPen = New-Object System.Drawing.Pen $track, (5.2 * $scale)
    $trackPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $trackPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $graphics.DrawEllipse($trackPen, $outerRect)

    if ($null -ne $FiveHourUsed) {
        $five = [Math]::Max(0, [Math]::Min(100, [double]$FiveHourUsed))
        $fivePen = New-Object System.Drawing.Pen (Get-UsageChartColor $Provider $five), (5.2 * $scale)
        $fivePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $fivePen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        if ($five -ge 99.95) {
            $graphics.DrawEllipse($fivePen, $outerRect)
        } elseif ($five -gt 0) {
            $graphics.DrawArc($fivePen, $outerRect, -90, [single](3.6 * $five))
        }
        $fivePen.Dispose()
    }

    $identityRect = New-Object System.Drawing.RectangleF (0.9 * $scale), (0.9 * $scale), (30.2 * $scale), (30.2 * $scale)
    $countdownTrackPen = New-Object System.Drawing.Pen $track, (2.0 * $scale)
    $graphics.DrawEllipse($countdownTrackPen, $identityRect)
    $remaining = [Math]::Max(0, [Math]::Min(100, $UpdateRemainingPercent))
    if ($remaining -gt 0) {
        $countdownPen = New-Object System.Drawing.Pen $base, (2.0 * $scale)
        $countdownPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $countdownPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        if ($remaining -ge 99.95) {
            $graphics.DrawEllipse($countdownPen, $identityRect)
        } else {
            $graphics.DrawArc($countdownPen, $identityRect, -90, [single](3.6 * $remaining))
        }
        $countdownPen.Dispose()
    }

    $innerRect = New-Object System.Drawing.RectangleF (9 * $scale), (9 * $scale), (14 * $scale), (14 * $scale)
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

    $innerPen.Dispose(); $innerTrackBrush.Dispose(); $countdownTrackPen.Dispose(); $trackPen.Dispose(); $graphics.Dispose()
    return $bitmap
}

function New-ProviderUsageIcon {
    param(
        [ValidateSet('Codex', 'Claude')][string]$Provider,
        [Nullable[double]]$FiveHourUsed,
        [Nullable[double]]$WeeklyUsed,
        [double]$UpdateRemainingPercent = 100
    )
    $bitmap = New-ProviderUsageBitmap $Provider $FiveHourUsed $WeeklyUsed $UpdateRemainingPercent 32
    $handle = $bitmap.GetHicon()
    try {
        return [System.Drawing.Icon]::FromHandle($handle).Clone()
    } finally {
        [LLMUsageMonitor.NativeIconMethods]::DestroyIcon($handle) | Out-Null
        $bitmap.Dispose()
    }
}
