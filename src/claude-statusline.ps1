$ErrorActionPreference = 'SilentlyContinue'
$inputText = [Console]::In.ReadToEnd()

try {
    $data = $inputText | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Output 'Claude | usage data unavailable'
    exit 0
}

function Get-RateValue($Window, [string]$Name) {
    if ($null -eq $Window) { return $null }
    $property = $Window.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

$five = $data.rate_limits.five_hour
$week = $data.rate_limits.seven_day
$fiveUsed = Get-RateValue $five 'used_percentage'
$weekUsed = Get-RateValue $week 'used_percentage'
$fiveReset = Get-RateValue $five 'resets_at'
$weekReset = Get-RateValue $week 'resets_at'
$contextUsed = if ($null -ne $data.context_window) { $data.context_window.used_percentage } else { $null }
$model = if ($null -ne $data.model -and $data.model.display_name) { $data.model.display_name } else { 'Claude' }

$outDir = if ($env:LLM_USAGE_DATA_DIR) { $env:LLM_USAGE_DATA_DIR } else { Join-Path $HOME '.ai-usage' }
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$jsonPath = Join-Path $outDir 'claude-code-usage.json'
$tempPath = Join-Path $outDir ('.claude-code-usage.{0}.tmp' -f $PID)

$result = [ordered]@{
    provider = 'claude_code'
    model = $model
    five_hour = [ordered]@{
        used_percent = $fiveUsed
        left_percent = if ($null -ne $fiveUsed) { 100 - [double]$fiveUsed } else { $null }
        resets_at_epoch = $fiveReset
    }
    weekly = [ordered]@{
        used_percent = $weekUsed
        left_percent = if ($null -ne $weekUsed) { 100 - [double]$weekUsed } else { $null }
        resets_at_epoch = $weekReset
    }
    context_window = [ordered]@{ used_percent = $contextUsed }
    source = 'claude_code_statusline'
    captured_at = [DateTimeOffset]::Now.ToString('o')
}

$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tempPath -Encoding UTF8
Move-Item -LiteralPath $tempPath -Destination $jsonPath -Force

$fiveText = if ($null -ne $fiveUsed) { '5h:{0}% used' -f [Math]::Round([double]$fiveUsed, 1) } else { '5h:?' }
$weekText = if ($null -ne $weekUsed) { '7d:{0}% used' -f [Math]::Round([double]$weekUsed, 1) } else { '7d:?' }
$ctxText = if ($null -ne $contextUsed) { 'ctx:{0}%' -f [Math]::Floor([double]$contextUsed) } else { 'ctx:?' }
Write-Output ("{0} | {1} | {2} | {3}" -f $model, $ctxText, $fiveText, $weekText)
