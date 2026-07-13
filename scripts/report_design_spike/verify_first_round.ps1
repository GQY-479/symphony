[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CaseDir,

    [string[]]$Variants = @("case-brief", "decision-memo", "review-narrative")
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$problems = New-Object "System.Collections.Generic.List[string]"

function Add-Problem {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $script:problems.Add($Message) | Out-Null
}

function Read-Json {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $content = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path
        if ([string]::IsNullOrWhiteSpace([string]$content)) {
            Add-Problem "JSON 无法解析：$Path"
            return $null
        }
        $value = $content | ConvertFrom-Json
    }
    catch {
        Add-Problem "JSON 无法解析：$Path"
        return $null
    }

    $trimmedContent = $content.TrimStart()
    if ($null -eq $value -or $trimmedContent.Length -eq 0 -or $trimmedContent[0] -ne "{") {
        Add-Problem "JSON 顶层必须是对象：$Path"
        return $null
    }

    return $value
}

function Read-Text {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $content = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path
        if ($null -eq $content) {
            $content = ""
        }
        return [pscustomobject]@{
            Success = $true
            Content = [string]$content
        }
    }
    catch {
        Add-Problem "文本无法读取：$Path"
        return [pscustomobject]@{
            Success = $false
            Content = $null
        }
    }
}

function Test-Screenshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$Mobile
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-Problem "缺少截图：$Path"
        return
    }

    $bitmap = $null
    try {
        $bitmap = New-Object System.Drawing.Bitmap($Path)

        if ($Mobile) {
            if ($bitmap.Width -lt 320 -or $bitmap.Width -gt 600 -or $bitmap.Height -lt 700) {
                Add-Problem "移动截图尺寸不合格：$Path"
            }
        }
        elseif ($bitmap.Width -lt 1200 -or $bitmap.Height -lt 700) {
            Add-Problem "桌面截图尺寸不合格：$Path"
        }

        $colors = New-Object "System.Collections.Generic.HashSet[int]"
        $ratios = @(0.1, 0.5, 0.9)
        foreach ($xRatio in $ratios) {
            foreach ($yRatio in $ratios) {
                $x = [Math]::Round(($bitmap.Width - 1) * $xRatio)
                $y = [Math]::Round(($bitmap.Height - 1) * $yRatio)
                $colors.Add($bitmap.GetPixel($x, $y).ToArgb()) | Out-Null
            }
        }

        if ($colors.Count -lt 2) {
            Add-Problem "截图为空白或单色：$Path"
        }
    }
    catch {
        Add-Problem "截图无法读取：$Path"
    }
    finally {
        if ($null -ne $bitmap) {
            $bitmap.Dispose()
        }
    }
}

function Test-HasProperty {
    param(
        [object]$Value,
        [string]$Name
    )

    return $null -ne $Value -and $Value.PSObject.Properties.Name -contains $Name
}

function Test-NonEmptyFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-Problem "缺少文件：$Path"
        return
    }

    $readResult = Read-Text -Path $Path
    if (-not $readResult.Success) {
        return
    }
    if ([string]::IsNullOrWhiteSpace($readResult.Content)) {
        Add-Problem "文件不能为空：$Path"
    }
}

$CaseDir = [System.IO.Path]::GetFullPath($CaseDir)

$canValidateVariants = $true
$variantValues = @($Variants)
if ($variantValues.Count -eq 0) {
    Add-Problem "至少提供一个候选"
    $canValidateVariants = $false
}
else {
    foreach ($variantValue in $variantValues) {
        if ([string]::IsNullOrWhiteSpace([string]$variantValue)) {
            Add-Problem "候选名称不能为空"
            $canValidateVariants = $false
        }
    }
}
if (-not $canValidateVariants) {
    $variantValues = @()
}

$contextPath = Join-Path $CaseDir "report_context.json"
$context = $null
if (-not (Test-Path -LiteralPath $contextPath -PathType Leaf)) {
    Add-Problem "缺少文件：$contextPath"
}
else {
    $context = Read-Json -Path $contextPath
}

if ($null -ne $context) {
    if ($context.schema_version -ne 1) {
        Add-Problem "report_context.json 的 schema_version 必须为 1"
    }
    if ($context.case_id -ne "YQE-134") {
        Add-Problem "report_context.json 的 case_id 必须为 YQE-134"
    }

    $issueIds = @($context.issues | ForEach-Object {
        if ($_ -is [string]) {
            $_
        }
        elseif (Test-HasProperty -Value $_ -Name "id") {
            $_.id
        }
    })
    foreach ($requiredIssue in @("YQE-134", "YQE-142", "YQE-143")) {
        if ($issueIds -notcontains $requiredIssue) {
            Add-Problem "report_context.json 缺少 issue：$requiredIssue"
        }
    }
}

$briefFields = @(
    "schema_version",
    "case_id",
    "audience",
    "decision_to_enable",
    "information_conflicts",
    "evidence_priorities",
    "narrative_hypothesis",
    "form_rationale",
    "visual_system",
    "discarded_alternatives",
    "assumptions"
)
$nonEmptyBriefFields = @(
    "decision_to_enable",
    "narrative_hypothesis",
    "form_rationale",
    "visual_system"
)

foreach ($variant in $variantValues) {
    $variantDir = Join-Path $CaseDir $variant
    if (-not (Test-Path -LiteralPath $variantDir -PathType Container)) {
        Add-Problem "缺少候选目录：$variantDir"
        continue
    }

    $briefPath = Join-Path $variantDir "report_brief.json"
    $htmlPath = Join-Path $variantDir "index.html"
    $summaryPath = Join-Path $variantDir "summary.md"
    $manifestPath = Join-Path $variantDir "manifest.json"
    $desktopScreenshotPath = Join-Path $variantDir "screenshot.png"
    $mobileScreenshotPath = Join-Path $variantDir "screenshot-mobile.png"
    $reviewPath = Join-Path $variantDir "review.md"

    $brief = $null
    if (-not (Test-Path -LiteralPath $briefPath -PathType Leaf)) {
        Add-Problem "缺少文件：$briefPath"
    }
    else {
        $brief = Read-Json -Path $briefPath
    }

    if ($null -ne $brief) {
        foreach ($field in $briefFields) {
            if (-not (Test-HasProperty -Value $brief -Name $field)) {
                Add-Problem "report_brief.json 缺少字段：$field（$variant）"
            }
        }
        if ($brief.case_id -ne "YQE-134") {
            Add-Problem "report_brief.json 的 case_id 必须为 YQE-134（$variant）"
        }
        foreach ($field in $nonEmptyBriefFields) {
            if (-not (Test-HasProperty -Value $brief -Name $field) -or
                [string]::IsNullOrWhiteSpace([string]$brief.$field)) {
                Add-Problem "report_brief.json 字段不能为空：$field（$variant）"
            }
        }
    }

    $manifest = $null
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Add-Problem "缺少文件：$manifestPath"
    }
    else {
        $manifest = Read-Json -Path $manifestPath
    }

    if ($null -ne $manifest) {
        if ($manifest.variant -ne $variant) {
            Add-Problem "manifest.json 的 variant 必须与目录名一致：$variant"
        }
        if ($manifest.status -ne "candidate") {
            Add-Problem "manifest.json 的 status 必须为 candidate：$variant"
        }
        if ($manifest.context_path -ne "../report_context.json") {
            Add-Problem "manifest.json 的 context_path 必须为 ../report_context.json：$variant"
        }
    }

    if (-not (Test-Path -LiteralPath $htmlPath -PathType Leaf)) {
        Add-Problem "缺少文件：$htmlPath"
    }
    else {
        $html = $null
        $htmlReadResult = Read-Text -Path $htmlPath
        if ($htmlReadResult.Success) {
            $html = $htmlReadResult.Content
            if ([string]::IsNullOrWhiteSpace($html)) {
                Add-Problem "文件不能为空：$htmlPath"
                $html = $null
            }
        }
        if ($null -ne $html) {
            foreach ($requiredIssue in @("YQE-134", "YQE-142", "YQE-143")) {
                if ($html -notmatch [regex]::Escape($requiredIssue)) {
                    Add-Problem "index.html 缺少 issue：$requiredIssue（$variant）"
                }
            }

            $remoteResourcePatterns = @(
                "(?is)<script\b[^>]*\bsrc\s*=",
                "(?is)<link\b[^>]*\bhref\s*=",
                "(?is)@import\b",
                '(?is)url\s*\(\s*[''"]?https?://',
                '(?is)<img\b[^>]*\bsrc\s*=\s*[''"]?https?://'
            )
            foreach ($pattern in $remoteResourcePatterns) {
                if ($html -match $pattern) {
                    Add-Problem "index.html 包含远程资源：$variant"
                    break
                }
            }
        }
    }

    Test-NonEmptyFile -Path $summaryPath
    Test-NonEmptyFile -Path $reviewPath
    Test-Screenshot -Path $desktopScreenshotPath
    Test-Screenshot -Path $mobileScreenshotPath -Mobile
}

if ($problems.Count -gt 0) {
    foreach ($problem in $problems) {
        Write-Error -Message $problem -ErrorAction Continue
    }
    exit 1
}

Write-Output "第一轮技术校验通过：$($Variants.Count) 个候选"
exit 0
