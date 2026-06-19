$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName System.Drawing
. (Join-Path $root 'src\TrayIcon.ps1')

$temporaryRoot = Join-Path $env:TEMP ('llm-usage-custom-icon-test-{0}' -f [Guid]::NewGuid().ToString('N'))
$iconsDirectory = Join-Path $temporaryRoot 'icons'

try {
    New-Item -ItemType Directory -Force -Path $iconsDirectory | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'src\CustomTrayIcon.example.ps1') -Destination (Join-Path $temporaryRoot 'CustomTrayIcon.ps1')

    foreach ($name in @('codex', 'claude')) {
        $bitmap = New-Object System.Drawing.Bitmap 32, 32
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        # Solid red is intentionally unmistakable when this test is run manually.
        $graphics.Clear([System.Drawing.Color]::Red)
        $handle = $bitmap.GetHicon()
        $icon = [System.Drawing.Icon]::FromHandle($handle).Clone()
        $stream = [System.IO.File]::Create((Join-Path $iconsDirectory ($name + '.ico')))
        try {
            $icon.Save($stream)
        } finally {
            $stream.Dispose()
            $icon.Dispose()
            [LLMUsageMonitor.NativeIconMethods]::DestroyIcon($handle) | Out-Null
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    }

    . (Join-Path $temporaryRoot 'CustomTrayIcon.ps1')
    foreach ($provider in @('Codex', 'Claude')) {
        $result = New-MonitorTrayIcon $provider 42 37 60
        try {
            if ($result -isnot [System.Drawing.Icon]) { throw "$provider custom renderer did not return an icon" }
            $rendered = $result.ToBitmap()
            try {
                $pixel = $rendered.GetPixel(16, 16)
                if ($pixel.R -ne 255 -or $pixel.G -ne 0 -or $pixel.B -ne 0) {
                    throw "$provider custom ICO was not loaded"
                }
            } finally {
                $rendered.Dispose()
            }
        } finally {
            if ($null -ne $result) { $result.Dispose() }
        }
    }

    Remove-Item -LiteralPath (Join-Path $iconsDirectory 'claude.ico')
    $fallback = New-MonitorTrayIcon 'Claude' 42 37 60
    try {
        if ($fallback -isnot [System.Drawing.Icon]) { throw 'Missing ICO did not fall back to the standard renderer' }
    } finally {
        if ($null -ne $fallback) { $fallback.Dispose() }
    }
} finally {
    Remove-Item -Path Function:\New-CustomProviderUsageIcon -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

Write-Host 'All CustomTrayIcon tests passed.' -ForegroundColor Green
