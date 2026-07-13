$ErrorActionPreference = "Stop"

$verifier = Join-Path $PSScriptRoot "verify_first_round.ps1"
if (-not (Test-Path -LiteralPath $verifier -PathType Leaf)) {
    throw "缺少被测脚本：$verifier"
}

Add-Type -AssemblyName System.Drawing

function Write-Json {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Write-TestImage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int]$Width,

        [Parameter(Mandatory = $true)]
        [int]$Height
    )

    $bitmap = $null
    $graphics = $null
    $brush = $null
    try {
        $bitmap = New-Object System.Drawing.Bitmap($Width, $Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::DarkRed)
        $graphics.Clear([System.Drawing.Color]::White)
        $stripeWidth = [Math]::Max(40, [int][Math]::Ceiling($Width / 4.0))
        $graphics.FillRectangle($brush, 0, 0, $stripeWidth, $Height)
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        if ($null -ne $brush) {
            $brush.Dispose()
        }
        if ($null -ne $graphics) {
            $graphics.Dispose()
        }
        if ($null -ne $bitmap) {
            $bitmap.Dispose()
        }
    }
}

function Invoke-Verifier {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CaseDir
    )

    $powershell = (Get-Process -Id $PID).Path
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $verifier -CaseDir $CaseDir *> $null
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Write-ValidCase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CaseDir
    )

    New-Item -ItemType Directory -Path $CaseDir -Force | Out-Null

    Write-Json -Path (Join-Path $CaseDir "report_context.json") -Value ([ordered]@{
        schema_version = 1
        case_id = "YQE-134"
        issues = @(
            [ordered]@{ id = "YQE-134" }
            [ordered]@{ id = "YQE-142" }
            [ordered]@{ id = "YQE-143" }
        )
    })

    $variants = @("case-brief", "decision-memo", "review-narrative")
    foreach ($variant in $variants) {
        $variantDir = Join-Path $CaseDir $variant
        New-Item -ItemType Directory -Path $variantDir -Force | Out-Null

        Write-Json -Path (Join-Path $variantDir "report_brief.json") -Value ([ordered]@{
            schema_version = 1
            case_id = "YQE-134"
            audience = "工程负责人"
            decision_to_enable = "决定是否进入下一轮人工评审"
            information_conflicts = @("范围与证据优先级需要权衡")
            evidence_priorities = @("验证结果", "实现证据")
            narrative_hypothesis = "以候选形式解释同一事实包"
            form_rationale = "验证 $variant 的表达能力"
            visual_system = "克制的工程报告视觉系统"
            discarded_alternatives = @("固定仪表盘")
            assumptions = @("读者熟悉工程任务语境")
        })

        @"
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <title>$variant</title>
  <style>body { color: #222; background: #fff; } strong { color: darkred; }</style>
</head>
<body>
  <h1>$variant</h1>
  <p><strong>YQE-134</strong> 汇总 YQE-142 与 YQE-143 的工程事实。</p>
</body>
</html>
"@ | Set-Content -LiteralPath (Join-Path $variantDir "index.html") -Encoding UTF8

        "# $variant`n`n候选报告摘要。" |
            Set-Content -LiteralPath (Join-Path $variantDir "summary.md") -Encoding UTF8

        Write-Json -Path (Join-Path $variantDir "manifest.json") -Value ([ordered]@{
            schema_version = 1
            case_id = "YQE-134"
            variant = $variant
            context_path = "../report_context.json"
            brief_path = "report_brief.json"
            html_path = "index.html"
            summary_path = "summary.md"
            review_path = "review.md"
            desktop_screenshot = "screenshot.png"
            mobile_screenshot = "screenshot-mobile.png"
            status = "candidate"
        })

        "# 评审状态`n`n待用户评审。" |
            Set-Content -LiteralPath (Join-Path $variantDir "review.md") -Encoding UTF8

        Write-TestImage -Path (Join-Path $variantDir "screenshot.png") -Width 1440 -Height 900
        Write-TestImage -Path (Join-Path $variantDir "screenshot-mobile.png") -Width 390 -Height 844
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("verify-first-round-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $emptyCase = Join-Path $testRoot "empty"
    New-Item -ItemType Directory -Path $emptyCase | Out-Null
    if ((Invoke-Verifier -CaseDir $emptyCase) -eq 0) {
        throw "场景 1 失败：空案例目录应返回非 0"
    }

    $validCase = Join-Path $testRoot "valid"
    Write-ValidCase -CaseDir $validCase
    if ((Invoke-Verifier -CaseDir $validCase) -ne 0) {
        throw "场景 2 失败：完整合法 artifact 应返回 0"
    }

    Add-Content -LiteralPath (Join-Path $validCase "case-brief\index.html") `
        -Value '<script src="https://example.com/app.js"></script>' -Encoding UTF8
    if ((Invoke-Verifier -CaseDir $validCase) -eq 0) {
        throw "场景 3 失败：远程脚本资源应返回非 0"
    }

    Write-Output "verify_first_round_tests：3/3 通过"
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
