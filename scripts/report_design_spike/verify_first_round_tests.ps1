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

function Invoke-PowerShellScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [string[]]$Arguments = @()
    )

    $powershell = (Get-Process -Id $PID).Path
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1 |
            Out-String
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output = $output
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Invoke-Verifier {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CaseDir
    )

    $result = Invoke-PowerShellScript -ScriptPath $verifier -Arguments @("-CaseDir", $CaseDir)
    return $result.ExitCode
}

function Test-OutputDiagnostic {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Output,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $compactOutput = $Output -replace "\s", ""
    $compactMessage = $Message -replace "\s", ""
    $compactPath = $Path -replace "\s", ""
    return $compactOutput -match [regex]::Escape($compactMessage) -and
        $compactOutput -match [regex]::Escape($compactPath)
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
            [ordered]@{ identifier = "YQE-134" }
            [ordered]@{ identifier = "YQE-142" }
            [ordered]@{ identifier = "YQE-143" }
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
        throw "场景 2 失败：identifier 契约的完整合法 artifact 应返回 0"
    }

    $zeroByteTextPaths = @(
        (Join-Path $validCase "case-brief\index.html"),
        (Join-Path $validCase "case-brief\summary.md"),
        (Join-Path $validCase "case-brief\review.md")
    )
    foreach ($zeroByteTextPath in $zeroByteTextPaths) {
        $originalContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $zeroByteTextPath
        try {
            [System.IO.File]::WriteAllBytes($zeroByteTextPath, [byte[]]@())
            $zeroByteTextResult = Invoke-PowerShellScript -ScriptPath $verifier `
                -Arguments @("-CaseDir", $validCase)
            if ($zeroByteTextResult.ExitCode -eq 0) {
                throw "零字节文本回归失败：$zeroByteTextPath 必须返回非 0"
            }
            if (-not (Test-OutputDiagnostic -Output $zeroByteTextResult.Output `
                    -Message "文件不能为空" -Path $zeroByteTextPath)) {
                throw "零字节文本回归失败：缺少带路径的内容无效诊断（$zeroByteTextPath）"
            }
        }
        finally {
            $originalContent | Set-Content -LiteralPath $zeroByteTextPath -Encoding UTF8
        }
    }

    $briefPath = Join-Path $validCase "case-brief\report_brief.json"
    $manifestPath = Join-Path $validCase "case-brief\manifest.json"
    $contextPath = Join-Path $validCase "report_context.json"
    $originalBrief = Get-Content -Raw -Encoding UTF8 -LiteralPath $briefPath
    $originalManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath
    $zeroByteJsonPaths = @($contextPath, $briefPath, $manifestPath)
    foreach ($zeroByteJsonPath in $zeroByteJsonPaths) {
        $originalContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $zeroByteJsonPath
        try {
            [System.IO.File]::WriteAllBytes($zeroByteJsonPath, [byte[]]@())
            $zeroByteJsonResult = Invoke-PowerShellScript -ScriptPath $verifier `
                -Arguments @("-CaseDir", $validCase)
            if ($zeroByteJsonResult.ExitCode -eq 0) {
                throw "零字节 JSON 回归失败：$zeroByteJsonPath 必须返回非 0"
            }
            if (-not (Test-OutputDiagnostic -Output $zeroByteJsonResult.Output `
                    -Message "JSON 无法解析" -Path $zeroByteJsonPath)) {
                throw "零字节 JSON 回归失败：缺少带路径的解析诊断（$zeroByteJsonPath）"
            }
        }
        finally {
            $originalContent | Set-Content -LiteralPath $zeroByteJsonPath -Encoding UTF8
        }
    }

    $reviewAfterZeroJsonPath = Join-Path $validCase "decision-memo\review.md"
    $originalContext = Get-Content -Raw -Encoding UTF8 -LiteralPath $contextPath
    $originalReviewAfterZeroJson = Get-Content -Raw -Encoding UTF8 -LiteralPath $reviewAfterZeroJsonPath
    try {
        [System.IO.File]::WriteAllBytes($contextPath, [byte[]]@())
        Remove-Item -LiteralPath $reviewAfterZeroJsonPath -Force
        $zeroJsonAndMissingReviewResult = Invoke-PowerShellScript -ScriptPath $verifier `
            -Arguments @("-CaseDir", $validCase)
        if (-not (Test-OutputDiagnostic -Output $zeroJsonAndMissingReviewResult.Output `
                -Message "JSON 无法解析" -Path $contextPath)) {
            throw "零字节 JSON 累计回归失败：缺少共享事实包解析诊断"
        }
        if (-not (Test-OutputDiagnostic -Output $zeroJsonAndMissingReviewResult.Output `
                -Message "缺少文件" -Path $reviewAfterZeroJsonPath)) {
            throw "零字节 JSON 累计回归失败：未累计后续 review.md 缺失问题"
        }
    }
    finally {
        $originalContext | Set-Content -LiteralPath $contextPath -Encoding UTF8
        $originalReviewAfterZeroJson |
            Set-Content -LiteralPath $reviewAfterZeroJsonPath -Encoding UTF8
    }

    $invalidTopLevels = @(
        [ordered]@{
            Name = "report_context.json 顶层 null"
            Path = $contextPath
            Content = "null"
        }
        [ordered]@{
            Name = "report_brief.json 顶层数组"
            Path = $briefPath
            Content = "[$originalBrief]"
        }
        [ordered]@{
            Name = "manifest.json 顶层数组"
            Path = $manifestPath
            Content = "[$originalManifest,$originalManifest]"
        }
    )
    foreach ($invalidTopLevel in $invalidTopLevels) {
        $originalContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $invalidTopLevel.Path
        try {
            $invalidTopLevel.Content |
                Set-Content -LiteralPath $invalidTopLevel.Path -Encoding UTF8
            $invalidTopLevelResult = Invoke-PowerShellScript -ScriptPath $verifier `
                -Arguments @("-CaseDir", $validCase)
            if ($invalidTopLevelResult.ExitCode -eq 0) {
                throw "顶层 JSON 回归失败：必须拒绝 $($invalidTopLevel.Name)"
            }
            if ($invalidTopLevelResult.Output -notmatch "JSON 顶层必须是对象" -or
                $invalidTopLevelResult.Output -match "JSON 无法解析") {
                throw "顶层 JSON 回归失败：诊断不清晰（$($invalidTopLevel.Name)）"
            }
        }
        finally {
            $originalContent | Set-Content -LiteralPath $invalidTopLevel.Path -Encoding UTF8
        }
    }

    $emptyVariantsRunner = Join-Path $testRoot "invoke-empty-variants.ps1"
    @'
param(
    [string]$Verifier,
    [string]$CaseDir
)

& $Verifier -CaseDir $CaseDir -Variants @()
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $emptyVariantsRunner -Encoding UTF8
    $emptyVariantsResult = Invoke-PowerShellScript -ScriptPath $emptyVariantsRunner `
        -Arguments @("-Verifier", $verifier, "-CaseDir", $validCase)
    if ($emptyVariantsResult.ExitCode -eq 0) {
        throw "Variants 回归失败：空 Variants 必须返回非 0；子进程输出：$($emptyVariantsResult.Output)"
    }
    if ($emptyVariantsResult.Output -notmatch "至少提供一个候选") {
        throw "Variants 回归失败：空 Variants 缺少清晰错误"
    }

    $summaryPath = Join-Path $validCase "case-brief\summary.md"
    $reviewPath = Join-Path $validCase "case-brief\review.md"
    $originalReview = Get-Content -Raw -Encoding UTF8 -LiteralPath $reviewPath
    $summaryLock = $null
    try {
        $summaryLock = [System.IO.File]::Open(
            $summaryPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        Remove-Item -LiteralPath $reviewPath -Force
        $textReadResult = Invoke-PowerShellScript -ScriptPath $verifier `
            -Arguments @("-CaseDir", $validCase)
        if ($textReadResult.ExitCode -eq 0) {
            throw "文本读取回归失败：不可读文件必须返回非 0"
        }
        if (-not (Test-OutputDiagnostic -Output $textReadResult.Output `
                -Message "文本无法读取" -Path $summaryPath)) {
            throw "文本读取回归失败：缺少不可读 summary.md 诊断；子进程输出：$($textReadResult.Output)"
        }
        if (-not (Test-OutputDiagnostic -Output $textReadResult.Output `
                -Message "缺少文件" -Path $reviewPath)) {
            throw "文本读取回归失败：未累计后续 review.md 缺失问题"
        }
    }
    finally {
        if ($null -ne $summaryLock) {
            $summaryLock.Dispose()
        }
        $originalReview | Set-Content -LiteralPath $reviewPath -Encoding UTF8
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
