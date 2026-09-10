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
    param([ValidateSet('Codex', 'Claude', 'Antigravity')][string]$Provider)
    if ($Provider -eq 'Codex') { return [System.Drawing.ColorTranslator]::FromHtml('#19BCE4') }
    if ($Provider -eq 'Antigravity') { return [System.Drawing.ColorTranslator]::FromHtml('#8B7CF6') }
    return [System.Drawing.ColorTranslator]::FromHtml('#D97757')
}

function Get-ProviderTrackColor {
    # Unused (remaining) share: a mid-lightness tint of each provider's colour,
    # light enough that 0% never reads like the dark-red "exhausted" state and
    # still identifies the icon.
    param([ValidateSet('Codex', 'Claude', 'Antigravity')][string]$Provider)
    if ($Provider -eq 'Codex') { return [System.Drawing.ColorTranslator]::FromHtml('#3E8FA3') }
    if ($Provider -eq 'Antigravity') { return [System.Drawing.ColorTranslator]::FromHtml('#6F66B8') }
    return [System.Drawing.ColorTranslator]::FromHtml('#A07A68')
}

function Get-UsageChartColor {
    param(
        [ValidateSet('Codex', 'Claude', 'Antigravity')][string]$Provider,
        [Nullable[double]]$UsedPercent
    )
    if ($null -eq $UsedPercent) { return [System.Drawing.Color]::FromArgb(135, 145, 155) }

    # Exhausted (100%) is dark red for every provider; grey read as "empty" on a
    # dark taskbar.
    if ($UsedPercent -ge 99.95) { return [System.Drawing.ColorTranslator]::FromHtml('#9B1C1C') }

    if ($Provider -eq 'Antigravity') {
        if ($UsedPercent -ge 90) { return [System.Drawing.ColorTranslator]::FromHtml('#F04444') }
        if ($UsedPercent -ge 70) { return [System.Drawing.ColorTranslator]::FromHtml('#FFB000') }
        return [System.Drawing.ColorTranslator]::FromHtml('#A99BFF')
    }

    if ($Provider -eq 'Codex') {
        if ($UsedPercent -ge 90) { return [System.Drawing.ColorTranslator]::FromHtml('#F04444') }
        if ($UsedPercent -ge 70) { return [System.Drawing.ColorTranslator]::FromHtml('#FFB000') }
        return [System.Drawing.ColorTranslator]::FromHtml('#32C7F0')
    }

    # Claude: hue steps that stay distinct at 16 px (orange -> yellow -> red).
    if ($UsedPercent -ge 90) { return [System.Drawing.ColorTranslator]::FromHtml('#FF3B30') }
    if ($UsedPercent -ge 70) { return [System.Drawing.ColorTranslator]::FromHtml('#FFD60A') }
    return [System.Drawing.ColorTranslator]::FromHtml('#D97757')
}

function Draw-ScopedLimitGauge {
    # Per-model weekly cap (Claude Fable) as a square gauge on the bottom layer,
    # visible only in the corners outside the circle. Sweeps clockwise from
    # 12 o'clock like the other gauges. Same colour steps as the body; a dark
    # rim around the circle keeps red corners from swallowing the body.
    param($Graphics, [double]$UsedPercent, [int]$Size)
    $scale = $Size / 32.0
    $corners = New-Object System.Drawing.Region (New-Object System.Drawing.RectangleF 0, 0, $Size, $Size)
    $circle = New-Object System.Drawing.Drawing2D.GraphicsPath
    $circle.AddEllipse((1.2 * $scale), (1.2 * $scale), (29.6 * $scale), (29.6 * $scale))
    $corners.Exclude($circle)
    $Graphics.SetClip($corners, [System.Drawing.Drawing2D.CombineMode]::Replace)

    $trackBrush = New-Object System.Drawing.SolidBrush (Get-ProviderTrackColor 'Claude')
    $Graphics.FillRectangle($trackBrush, 0, 0, $Size, $Size)
    $used = [Math]::Max(0, [Math]::Min(100, $UsedPercent))
    if ($used -gt 0) {
        $fillBrush = New-Object System.Drawing.SolidBrush (Get-UsageChartColor 'Claude' $used)
        $Graphics.FillPie($fillBrush, (-$Size / 2), (-$Size / 2), (2 * $Size), (2 * $Size), -90, [single](3.6 * $used))
        $fillBrush.Dispose()
    }
    $Graphics.ResetClip()
    $rim = New-Object System.Drawing.Pen ([System.Drawing.ColorTranslator]::FromHtml('#111111')), (2.8 * $scale)
    $Graphics.DrawEllipse($rim, (1.2 * $scale), (1.2 * $scale), (29.6 * $scale), (29.6 * $scale))
    $rim.Dispose(); $trackBrush.Dispose(); $circle.Dispose(); $corners.Dispose()
}

function New-ProviderUsageBitmap {
    param(
        [ValidateSet('Codex', 'Claude', 'Antigravity')][string]$Provider,
        [Nullable[double]]$FiveHourUsed,
        [Nullable[double]]$WeeklyUsed,
        [Nullable[double]]$FiveHourResetRemainingPercent = $null,
        [int]$Size = 32,
        [Nullable[double]]$ScopedUsed = $null
    )

    $bitmap = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

    $scale = $Size / 32.0
    $base = Get-ProviderBaseColor $Provider
    $track = Get-ProviderTrackColor $Provider
    # Claude: once either window reaches 90%, the whole icon turns red so a
    # nearly-full weekly (the small inner pie) is not missed at 16 px.
    $peak = @($FiveHourUsed, $WeeklyUsed) | Where-Object { $null -ne $_ } | Measure-Object -Maximum
    if ($Provider -eq 'Claude' -and $peak.Count -gt 0 -and $peak.Maximum -ge 90) {
        $base = [System.Drawing.ColorTranslator]::FromHtml('#FF3B30')
        $track = [System.Drawing.ColorTranslator]::FromHtml('#6B1111')
    }
    if ($null -ne $ScopedUsed) {
        Draw-ScopedLimitGauge $graphics ([double]$ScopedUsed) $Size
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
        [ValidateSet('Codex', 'Claude', 'Antigravity')][string]$Provider,
        [Nullable[double]]$FiveHourUsed,
        [Nullable[double]]$WeeklyUsed,
        [Nullable[double]]$FiveHourResetRemainingPercent = $null,
        [Nullable[double]]$ScopedUsed = $null
    )
    $bitmap = New-ProviderUsageBitmap $Provider $FiveHourUsed $WeeklyUsed $FiveHourResetRemainingPercent 32 $ScopedUsed
    $handle = $bitmap.GetHicon()
    try {
        return [System.Drawing.Icon]::FromHandle($handle).Clone()
    } finally {
        [LLMUsageMonitor.NativeIconMethods]::DestroyIcon($handle) | Out-Null
        $bitmap.Dispose()
    }
}

function New-MonitorTrayIcon {
    [CmdletBinding()]
    param(
        [string]$Provider,
        [Nullable[double]]$FiveHourUsed,
        [Nullable[double]]$WeeklyUsed,
        [Nullable[double]]$FiveHourResetRemainingPercent = $null,
        [Nullable[double]]$ScopedUsed = $null
    )

    $customRenderer = Get-Command -Name 'New-CustomProviderUsageIcon' -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $customRenderer) {
        try {
            $customIcon = New-CustomProviderUsageIcon `
                -Provider $Provider `
                -FiveHourUsed $FiveHourUsed `
                -WeeklyUsed $WeeklyUsed `
                -FiveHourResetRemainingPercent $FiveHourResetRemainingPercent
            if ($customIcon -is [System.Drawing.Icon]) { return $customIcon }
            if ($null -ne $customIcon) {
                Write-Warning 'New-CustomProviderUsageIcon must return System.Drawing.Icon or $null. Using the default renderer.'
            }
        } catch {
            Write-Warning ('Custom tray icon renderer failed: {0}. Using the default renderer.' -f $_.Exception.Message)
        }
    }

    return New-ProviderUsageIcon $Provider $FiveHourUsed $WeeklyUsed $FiveHourResetRemainingPercent $ScopedUsed
}
