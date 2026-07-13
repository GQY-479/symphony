# YQE-134 工程汇报同案三解实施计划

> **面向执行 Agent：** 必须使用 `superpowers:subagent-driven-development`（推荐）或
> `superpowers:executing-plans` 逐任务执行本计划。执行设计任务时必须同时使用
> `huashu-design`，浏览器验证时必须使用 `browser:control-in-app-browser`。
> 任务步骤使用复选框（`- [ ]`）跟踪。

**目标：** 基于 YQE-134、YQE-142 和 YQE-143 的真实 Linear 事实，制作案件 brief、决策 memo、审查叙事三种结构不同的工程 HTML 汇报，并提供可直接比较的人工评审入口。

**架构：** 三个候选报告共用一份只含事实和证据的 `report_context.json` 与一份设计输入，但各自拥有独立的 `report_brief.json`、单文件 HTML、摘要、manifest、截图和评审表。PowerShell verifier 只检查文件集合、事实引用、自包含资源和截图有效性，不检查固定章节或 DOM id；form 是否成立仍由人工评审决定。

**技术栈：** PowerShell、JSON、静态 HTML/CSS、Linear GraphQL、`huashu-design`、Codex in-app Browser。

---

## 范围和停止条件

本计划只执行已批准 spec 的第一轮“YQE-134 同案三解”。完成三版和评审入口后停止，等待用户接受、拒绝或提出混合方向，不自动进入成功功能案例和批量返工 workflow。

执行期间遵守以下边界：

1. 不修改或提交 `elixir/lib/symphony_elixir/workflow/report_spike/`。
2. 不修改或提交 `elixir/test/fixtures/report_spikes/` 和旧的 `workflow_report_spike_test.exs`。
3. 不修改或提交 `.symphony/report-spikes/` 与 `.symphony/huashu-demo/`。
4. 只使用 Linear 只读查询，不创建评论、不改变 issue 状态。
5. 三版不使用图片、logo 或远程字体；本案例是工程判断文档，图像不是内容必需资产。
6. 三版都必须引用同一份 `report_context.json`，不得根据版式改写事实。
7. 三版结构必须不同，不能只换颜色、字体或卡片样式。
8. 候选 artifact 可以提交到 `.symphony/report-design-spike/yqe-134/`，但必须逐路径暂存，不能使用覆盖整个工作区的 `git add -A`。

## 文件结构

### 受版本控制的验证脚本

- 创建：`scripts/report_design_spike/verify_first_round.ps1`
  - 只验证第一轮 artifact 的技术下限。
- 创建：`scripts/report_design_spike/verify_first_round_tests.ps1`
  - 使用临时目录验证缺文件、合法 artifact、远程资源三种情况。

### 本轮设计 artifact

- 创建：`.symphony/report-design-spike/yqe-134/report_context.json`
  - 三版共用的真实事实、冲突、证据和动作。
- 创建：`.symphony/report-design-spike/yqe-134/design-input.md`
  - 三个设计上下文的唯一共同说明。
- 创建：`.symphony/report-design-spike/yqe-134/case-brief/`
  - 案件 brief 的 brief、HTML、摘要、manifest、截图和评审表。
- 创建：`.symphony/report-design-spike/yqe-134/decision-memo/`
  - 决策 memo 的同构 artifact 集合。
- 创建：`.symphony/report-design-spike/yqe-134/review-narrative/`
  - 审查叙事的同构 artifact 集合。
- 创建：`.symphony/report-design-spike/yqe-134/review-index.html`
  - 三版并排比较入口，不是生产 dashboard。
- 创建：`.symphony/report-design-spike/yqe-134/review-index.png`
  - 评审入口桌面截图。
- 创建：`.symphony/report-design-spike/yqe-134/review-index-mobile.png`
  - 评审入口窄屏截图。

每个候选目录固定包含：

```text
report_brief.json
index.html
summary.md
manifest.json
screenshot.png
screenshot-mobile.png
review.md
```

## 为什么计划不预写三份完整 HTML

三份 HTML 的事实、读者任务、叙事角色、必含判断、禁止项、验证命令和输出路径在本计划中全部固定；具体布局、排印和视觉母题由执行时的独立设计上下文产生。

把完整 HTML 源码提前写进计划，等同于在设计探索前固定 renderer，会直接违反已批准 spec 的“先设计，后抽象”和“同案多解”原则。因此，HTML 是本计划中唯一不展开完整源码的 artifact；这不是待补实现，而是经过批准的开放 form 边界。

---

### Task 1：建立只检查技术下限的 verifier

**文件：**

- 创建：`scripts/report_design_spike/verify_first_round_tests.ps1`
- 创建：`scripts/report_design_spike/verify_first_round.ps1`

- [ ] **Step 1：先写原生 PowerShell 测试**

创建 `scripts/report_design_spike/verify_first_round_tests.ps1`：

```powershell
$ErrorActionPreference = "Stop"

$verifier = Join-Path $PSScriptRoot "verify_first_round.ps1"
if (-not (Test-Path -LiteralPath $verifier)) {
  throw "缺少被测脚本：$verifier"
}

Add-Type -AssemblyName System.Drawing

function Write-Json {
  param([string]$Path, [object]$Value)
  $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Write-TestImage {
  param([string]$Path, [int]$Width, [int]$Height)

  $bitmap = [System.Drawing.Bitmap]::new($Width, $Height)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

  try {
    $graphics.Clear([System.Drawing.Color]::White)
    $brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::DarkRed)
    try {
      $graphics.FillRectangle($brush, 0, 0, [Math]::Max(40, [int]($Width / 4)), $Height)
    } finally {
      $brush.Dispose()
    }
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally {
    $graphics.Dispose()
    $bitmap.Dispose()
  }
}

function Invoke-Verifier {
  param([string]$CaseDir)

  $powershell = (Get-Process -Id $PID).Path
  & $powershell -NoProfile -ExecutionPolicy Bypass -File $verifier -CaseDir $CaseDir *> $null
  return $LASTEXITCODE
}

function Write-ValidCase {
  param([string]$CaseDir)

  New-Item -ItemType Directory -Path $CaseDir -Force | Out-Null
  Write-Json (Join-Path $CaseDir "report_context.json") @{
    schema_version = 1
    case_id = "YQE-134"
    issues = @(
      @{ identifier = "YQE-134" },
      @{ identifier = "YQE-142" },
      @{ identifier = "YQE-143" }
    )
  }

  foreach ($variant in @("case-brief", "decision-memo", "review-narrative")) {
    $variantDir = Join-Path $CaseDir $variant
    New-Item -ItemType Directory -Path $variantDir -Force | Out-Null

    Write-Json (Join-Path $variantDir "report_brief.json") @{
      schema_version = 1
      case_id = "YQE-134"
      audience = "workflow owner"
      decision_to_enable = "判断 root 是否可信完成"
      information_conflicts = @("表面状态与审查结论冲突")
      evidence_priorities = @("E-001")
      narrative_hypothesis = "测试叙事假设 $variant"
      form_rationale = "测试 form 来源 $variant"
      visual_system = "测试视觉系统 $variant"
      discarded_alternatives = @()
      assumptions = @()
    }

    @"
<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><style>body{background:#fff;color:#111}</style></head>
<body><main>YQE-134 YQE-142 YQE-143 $variant</main></body>
</html>
"@ | Set-Content -LiteralPath (Join-Path $variantDir "index.html") -Encoding UTF8

    "# 摘要`n`nYQE-134 当前不能视为可信完成。" |
      Set-Content -LiteralPath (Join-Path $variantDir "summary.md") -Encoding UTF8

    Write-Json (Join-Path $variantDir "manifest.json") @{
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
    }

    "# 人工评审`n`n评审状态：待用户评审" |
      Set-Content -LiteralPath (Join-Path $variantDir "review.md") -Encoding UTF8

    Write-TestImage (Join-Path $variantDir "screenshot.png") 1440 900
    Write-TestImage (Join-Path $variantDir "screenshot-mobile.png") 390 844
  }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("report-spike-test-" + [guid]::NewGuid())

try {
  $missingCase = Join-Path $tempRoot "missing"
  New-Item -ItemType Directory -Path $missingCase -Force | Out-Null
  if ((Invoke-Verifier $missingCase) -eq 0) {
    throw "缺文件场景应失败，但 verifier 返回成功"
  }

  $validCase = Join-Path $tempRoot "valid"
  Write-ValidCase $validCase
  if ((Invoke-Verifier $validCase) -ne 0) {
    throw "合法 artifact 场景应通过，但 verifier 返回失败"
  }

  Add-Content -LiteralPath (Join-Path $validCase "case-brief\index.html") -Value '<script src="https://example.com/app.js"></script>'
  if ((Invoke-Verifier $validCase) -eq 0) {
    throw "远程资源场景应失败，但 verifier 返回成功"
  }

  Write-Output "verify_first_round_tests：3/3 通过"
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
```

- [ ] **Step 2：运行测试，确认 verifier 尚不存在时失败**

运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/report_design_spike/verify_first_round_tests.ps1
```

预期：失败并输出 `缺少被测脚本`。

- [ ] **Step 3：实现最小 verifier**

创建 `scripts/report_design_spike/verify_first_round.ps1`：

```powershell
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
  param([string]$Message)
  $problems.Add($Message)
}

function Read-Json {
  param([string]$Path)

  try {
    return Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json
  } catch {
    Add-Problem "JSON 无法解析：$Path"
    return $null
  }
}

function Test-Screenshot {
  param([string]$Path, [string]$Kind)

  if (-not (Test-Path -LiteralPath $Path)) {
    Add-Problem "缺少截图：$Path"
    return
  }

  try {
    $bitmap = [System.Drawing.Bitmap]::new($Path)
  } catch {
    Add-Problem "截图无法读取：$Path"
    return
  }

  try {
    if ($Kind -eq "desktop" -and ($bitmap.Width -lt 1200 -or $bitmap.Height -lt 700)) {
      Add-Problem "桌面截图尺寸不足：$Path ($($bitmap.Width)x$($bitmap.Height))"
    }

    if ($Kind -eq "mobile" -and
        ($bitmap.Width -lt 320 -or $bitmap.Width -gt 600 -or $bitmap.Height -lt 700)) {
      Add-Problem "窄屏截图尺寸不符合要求：$Path ($($bitmap.Width)x$($bitmap.Height))"
    }

    $colors = New-Object "System.Collections.Generic.HashSet[int]"
    foreach ($xRatio in @(0.1, 0.5, 0.9)) {
      foreach ($yRatio in @(0.1, 0.5, 0.9)) {
        $x = [Math]::Min($bitmap.Width - 1, [int]($bitmap.Width * $xRatio))
        $y = [Math]::Min($bitmap.Height - 1, [int]($bitmap.Height * $yRatio))
        $null = $colors.Add($bitmap.GetPixel($x, $y).ToArgb())
      }
    }

    if ($colors.Count -lt 2) {
      Add-Problem "截图采样结果为空白或单色：$Path"
    }
  } finally {
    $bitmap.Dispose()
  }
}

$resolvedCaseDir = [System.IO.Path]::GetFullPath($CaseDir)
$contextPath = Join-Path $resolvedCaseDir "report_context.json"

if (-not (Test-Path -LiteralPath $contextPath)) {
  Add-Problem "缺少事实包：$contextPath"
  $context = $null
} else {
  $context = Read-Json $contextPath
}

if ($null -ne $context) {
  if ($context.schema_version -ne 1) {
    Add-Problem "report_context.schema_version 必须为 1"
  }

  if ($context.case_id -ne "YQE-134") {
    Add-Problem "report_context.case_id 必须为 YQE-134"
  }

  $issueIds = @($context.issues | ForEach-Object { $_.identifier })
  foreach ($issueId in @("YQE-134", "YQE-142", "YQE-143")) {
    if ($issueIds -notcontains $issueId) {
      Add-Problem "事实包缺少 issue：$issueId"
    }
  }
}

$requiredBriefFields = @(
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

$requiredFiles = @(
  "report_brief.json",
  "index.html",
  "summary.md",
  "manifest.json",
  "screenshot.png",
  "screenshot-mobile.png",
  "review.md"
)

$forbiddenResourcePatterns = @(
  '<script\b[^>]*\bsrc\s*=',
  '<link\b[^>]*\bhref\s*=',
  '@import\s+',
  'url\(\s*["'']?https?://',
  '<img\b[^>]*\bsrc\s*=\s*["'']https?://'
)

foreach ($variant in $Variants) {
  $variantDir = Join-Path $resolvedCaseDir $variant

  if (-not (Test-Path -LiteralPath $variantDir)) {
    Add-Problem "缺少候选目录：$variantDir"
    continue
  }

  foreach ($requiredFile in $requiredFiles) {
    $requiredPath = Join-Path $variantDir $requiredFile
    if (-not (Test-Path -LiteralPath $requiredPath)) {
      Add-Problem "缺少候选文件：$requiredPath"
    }
  }

  $briefPath = Join-Path $variantDir "report_brief.json"
  if (Test-Path -LiteralPath $briefPath) {
    $brief = Read-Json $briefPath
    if ($null -ne $brief) {
      $briefFields = @($brief.PSObject.Properties.Name)
      foreach ($field in $requiredBriefFields) {
        if ($briefFields -notcontains $field) {
          Add-Problem "$variant 的 report_brief 缺少字段：$field"
        }
      }

      if ($brief.case_id -ne "YQE-134") {
        Add-Problem "$variant 的 report_brief.case_id 必须为 YQE-134"
      }

      foreach ($field in @("decision_to_enable", "narrative_hypothesis", "form_rationale", "visual_system")) {
        if ([string]::IsNullOrWhiteSpace([string]$brief.$field)) {
          Add-Problem "$variant 的 report_brief.$field 不能为空"
        }
      }
    }
  }

  $manifestPath = Join-Path $variantDir "manifest.json"
  if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Read-Json $manifestPath
    if ($null -ne $manifest) {
      if ($manifest.variant -ne $variant) {
        Add-Problem "$variant 的 manifest.variant 与目录名不一致"
      }

      if ($manifest.status -ne "candidate") {
        Add-Problem "$variant 的 manifest.status 必须为 candidate"
      }

      if ($manifest.context_path -ne "../report_context.json") {
        Add-Problem "$variant 的 manifest.context_path 必须引用共享事实包"
      }
    }
  }

  $htmlPath = Join-Path $variantDir "index.html"
  if (Test-Path -LiteralPath $htmlPath) {
    $html = Get-Content -Raw -Encoding UTF8 -LiteralPath $htmlPath

    foreach ($issueId in @("YQE-134", "YQE-142", "YQE-143")) {
      if (-not $html.Contains($issueId)) {
        Add-Problem "$variant 的 HTML 未引用 $issueId"
      }
    }

    foreach ($pattern in $forbiddenResourcePatterns) {
      if ($html -match $pattern) {
        Add-Problem "$variant 的 HTML 包含远程资源：$pattern"
      }
    }
  }

  foreach ($textFile in @("summary.md", "review.md")) {
    $textPath = Join-Path $variantDir $textFile
    if (Test-Path -LiteralPath $textPath) {
      $content = Get-Content -Raw -Encoding UTF8 -LiteralPath $textPath
      if ([string]::IsNullOrWhiteSpace($content)) {
        Add-Problem "$variant 的 $textFile 不能为空"
      }
    }
  }

  Test-Screenshot (Join-Path $variantDir "screenshot.png") "desktop"
  Test-Screenshot (Join-Path $variantDir "screenshot-mobile.png") "mobile"
}

if ($problems.Count -gt 0) {
  foreach ($problem in $problems) {
    Write-Error $problem
  }
  exit 1
}

Write-Output "第一轮技术校验通过：$($Variants.Count) 个候选"
exit 0
```

- [ ] **Step 4：运行测试，确认三种场景通过**

运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/report_design_spike/verify_first_round_tests.ps1
```

预期：输出 `verify_first_round_tests：3/3 通过`。

- [ ] **Step 5：提交 verifier**

运行：

```powershell
git add -- scripts/report_design_spike/verify_first_round.ps1 scripts/report_design_spike/verify_first_round_tests.ps1
git diff --cached --check
```

调用仓库 `commit` skill 创建提交，建议 subject：

```text
test(report): 校验设计 spike 技术下限
```

预期：提交只包含两个 PowerShell 文件，正文记录测试命令和为何只校验技术下限。

---

### Task 2：冻结 YQE-134 真实事实和共同设计输入

**文件：**

- 创建：`.symphony/report-design-spike/yqe-134/report_context.json`
- 创建：`.symphony/report-design-spike/yqe-134/design-input.md`

- [ ] **Step 1：只读复核三个 Linear issue**

使用 `linear` skill 的 `linear_issue_read` 高层工具分别读取 `YQE-134`、`YQE-142` 和 `YQE-143`，至少读取：

```text
identifier
title
url
description
state { name type }
createdAt
updatedAt
completedAt
comments { body createdAt updatedAt }
history { createdAt fromState toState }
```

确认以下事实仍成立：

1. YQE-134 当前 Linear 状态为 `Done`。
2. YQE-142 的 Issue Result 自报 `completed`。
3. YQE-143 的审查评论分别给出 `fail` 和 `needs_rework`。
4. YQE-143 的审查证据指出三个目标函数 grep 为 0，目标渲染点仍输出纯文本。
5. YQE-134 在 2026-06-30 经历 `Done -> In Progress -> Done`。

任何事实发生变化时，以本次只读结果为准更新事实包，同时保留历史评论时间，不能为了保持旧 demo 结论而忽略新证据。

- [ ] **Step 2：写入共享事实包**

创建 `.symphony/report-design-spike/yqe-134/report_context.json`：

```json
{
  "schema_version": 1,
  "case_id": "YQE-134",
  "snapshot_date": "2026-07-13",
  "source": "Linear GraphQL read-only snapshot",
  "subject": {
    "identifier": "YQE-134",
    "title": "我希望当在一个issue里引用其他issue的时候，是一个可达的链接。这个操作最好是不耗token的",
    "url": "https://linear.app/yqeeqy/issue/YQE-134/我希望当在一个issue里引用其他issue的时候是一个可达的链接这个操作最好是不耗token的",
    "surface_state": "Done",
    "latest_review_outcome": "needs_rework"
  },
  "issues": [
    {
      "identifier": "YQE-134",
      "title": "我希望当在一个issue里引用其他issue的时候，是一个可达的链接。这个操作最好是不耗token的",
      "url": "https://linear.app/yqeeqy/issue/YQE-134/我希望当在一个issue里引用其他issue的时候是一个可达的链接这个操作最好是不耗token的",
      "role": "root",
      "state": "Done",
      "state_type": "completed",
      "updated_at": "2026-06-30T16:44:49.414Z",
      "history": [
        "2026-06-30T16:14:06.035Z In Progress -> Done",
        "2026-06-30T16:25:24.952Z Done -> In Progress",
        "2026-06-30T16:44:49.371Z In Progress -> Done"
      ]
    },
    {
      "identifier": "YQE-142",
      "title": "issue identifier 链接化",
      "url": "https://linear.app/yqeeqy/issue/YQE-142/issue-identifier-链接化",
      "role": "implementation",
      "state": "Done",
      "state_type": "completed",
      "updated_at": "2026-06-30T01:06:16.483Z",
      "reported_outcome": "completed",
      "reported_summary": "自报 controller 已包含 issue_link/2、issue_url/2、extract_team_domain/1，并称 28 tests, 0 failures"
    },
    {
      "identifier": "YQE-143",
      "title": "最终审查",
      "url": "https://linear.app/yqeeqy/issue/YQE-143/最终审查",
      "role": "final_review",
      "state": "Done",
      "state_type": "completed",
      "updated_at": "2026-06-30T16:07:04.666Z",
      "review_results": [
        {
          "created_at": "2026-06-30T01:41:58.363Z",
          "outcome": "fail"
        },
        {
          "created_at": "2026-06-30T16:07:02.294Z",
          "outcome": "needs_rework"
        }
      ]
    }
  ],
  "conflicts": [
    {
      "id": "C-001",
      "surface": "YQE-134 当前状态为 Done",
      "counter_evidence": "YQE-143 最终审查结论为 needs_rework",
      "meaning": "Linear terminal state 不能单独作为可信完成证明"
    },
    {
      "id": "C-002",
      "surface": "YQE-142 自报三个链接函数已经实现且测试通过",
      "counter_evidence": "YQE-143 在 root 和 implementation workspace 中 grep 三个函数均为 0 matches",
      "meaning": "实现自报与代码证据直接冲突"
    },
    {
      "id": "C-003",
      "surface": "YQE-143 issue 自身状态为 Done",
      "counter_evidence": "其 Issue Result outcome 为 fail 和 needs_rework",
      "meaning": "审查任务完成不等于被审查实现通过"
    }
  ],
  "evidence": [
    {
      "id": "E-001",
      "source_issue": "YQE-142",
      "source_type": "issue_result_comment",
      "created_at": "2026-06-30T01:06:15.388Z",
      "proves": "implementation agent 自报完成并声称测试通过"
    },
    {
      "id": "E-002",
      "source_issue": "YQE-143",
      "source_type": "review_comment",
      "created_at": "2026-06-30T16:07:02.294Z",
      "proves": "最终审查给出 needs_rework"
    },
    {
      "id": "E-003",
      "source_issue": "YQE-143",
      "source_type": "grep_evidence",
      "proves": "root 和 implementation workspace 中 issue_link/2、issue_url/2、extract_team_domain/1 均为 0 matches"
    },
    {
      "id": "E-004",
      "source_issue": "YQE-143",
      "source_type": "diff_evidence",
      "proves": "controller.ex diff 只有行尾变化和 validate_node_agents，没有链接实现"
    },
    {
      "id": "E-005",
      "source_issue": "YQE-143",
      "source_type": "render_evidence",
      "proves": "render_plan_comment、render_issue_result_comment、node_description 仍输出纯文本 identifier"
    },
    {
      "id": "E-006",
      "source_issue": "YQE-143",
      "source_type": "test_evidence",
      "proves": "YQE-142 测试引用 issue_link/2，但函数不存在，因此自报测试结果不可直接采信"
    },
    {
      "id": "E-007",
      "source_issue": "YQE-134",
      "source_type": "state_history",
      "proves": "root 在最终审查后经历 Done、In Progress、Done 状态往返"
    }
  ]
}
```

- [ ] **Step 3：写入三版唯一共同设计输入**

创建 `.symphony/report-design-spike/yqe-134/design-input.md`：

```markdown
# YQE-134 工程汇报设计输入

## 任务本质

这不是状态 dashboard，也不是 Linear 字段汇总。页面要帮助 workflow owner 判断一个表面为 Done 的 root issue 是否已经可信交付。真正的阅读难点是三层语义互相冲突：implementation agent 自报完成，final review 证明核心实现不存在，而 root 和 review issue 最终都显示 Done。

## 读者和场景

主要读者是 Symphony workflow owner。主要场景是在笔记本上打开本地 HTML，在 1 到 3 分钟内决定是否需要返工、依据是什么、下一步由谁执行。窄屏用于快速复核，不要求把全部证据压进首屏。

## 三版共同事实

三版只能使用 `report_context.json`。必须同时出现 YQE-134、YQE-142、YQE-143，并准确表达：root 的表面状态是 Done；implementation 自报 completed；final review 的 outcome 是 fail / needs_rework；审查证据指向核心函数和渲染改动不存在；root 在审查后发生状态往返。

## 三版共同判断

当前不能把 YQE-134 视为可信完成。推荐动作是恢复 active / needs_rework，重新实现或提交反证，重新运行测试并进行独立审查。页面不能把“review issue 已 Done”误写成“review 已通过”。

## 输出形式

输出是可双击打开的单文件 HTML。桌面基准视口为 1440 x 900，窄屏基准视口为 390 x 844。CSS 和必要 JS 内嵌，不加载远程字体、脚本、样式或图片。证据链接可以使用普通 `<a href>` 指向 Linear，但不得用远程资源参与页面渲染。

## 图片判断

图片不是内容必需资产。本案例的主要材料是状态冲突、审查证据和动作，不使用 stock 图、logo、装饰性插画或手绘 SVG。视觉母题必须来自事实关系和阅读任务。

## 可读性下限

正文不小于 14px，标签和注释不小于 12px，正文对比度至少 4.5:1。首屏必须给出当前判断、表面状态为什么不可信、最关键证据和所需动作。长评论、原始 JSON 和长证据默认折叠。任何关键结论附近都要说明证据证明了什么。

## 三个叙事角色

1. `case-brief`：像案件卷宗一样组织情况、冲突、判定、证据链和处置。
2. `decision-memo`：围绕“能否接受完成”这一决定组织选项、判据、推理和建议。
3. `review-narrative`：findings first，组织严重性、主张、反证、影响和重新通过条件。

## 禁止项

不使用 dashboard 作为默认构图，不做 KPI 卡片阵列，不把三版做成同一骨架换肤，不编造统计数字，不用 emoji 充当图标，不使用紫蓝渐变和通用霓虹，不让矩阵或时间线取代结论。
```

- [ ] **Step 4：验证事实包可以解析且 verifier 会因候选尚未生成而失败**

运行：

```powershell
$context = Get-Content -Raw -Encoding UTF8 .symphony/report-design-spike/yqe-134/report_context.json | ConvertFrom-Json
if ($context.case_id -ne "YQE-134") { throw "case_id 错误" }
if (@($context.issues).Count -ne 3) { throw "issue 数量错误" }
if (@($context.conflicts).Count -ne 3) { throw "冲突数量错误" }
if (@($context.evidence).Count -ne 7) { throw "证据数量错误" }
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/report_design_spike/verify_first_round.ps1 -CaseDir .symphony/report-design-spike/yqe-134
```

预期：JSON 断言通过；verifier 因三个候选目录尚未创建而失败。

- [ ] **Step 5：扫描事实包中的敏感信息并提交**

运行：

```powershell
rg -n -i "LINEAR_API_KEY|Bearer |api[_-]?key" .symphony/report-design-spike/yqe-134
git add -- .symphony/report-design-spike/yqe-134/report_context.json .symphony/report-design-spike/yqe-134/design-input.md
git diff --cached --check
```

调用仓库 `commit` skill 创建提交，建议 subject：

```text
docs(report): 冻结 YQE-134 设计事实包
```

预期：`rg` 无匹配；提交只包含事实包和共同设计输入。

---

### Task 3：制作案件 brief 候选

**文件：**

- 创建：`.symphony/report-design-spike/yqe-134/case-brief/report_brief.json`
- 创建：`.symphony/report-design-spike/yqe-134/case-brief/index.html`
- 创建：`.symphony/report-design-spike/yqe-134/case-brief/summary.md`
- 创建：`.symphony/report-design-spike/yqe-134/case-brief/manifest.json`
- 创建：`.symphony/report-design-spike/yqe-134/case-brief/screenshot.png`
- 创建：`.symphony/report-design-spike/yqe-134/case-brief/screenshot-mobile.png`
- 创建：`.symphony/report-design-spike/yqe-134/case-brief/review.md`

- [ ] **Step 1：写案件 brief 的设计判断**

创建 `report_brief.json`，内容如下：

```json
{
  "schema_version": 1,
  "case_id": "YQE-134",
  "audience": "workflow owner",
  "decision_to_enable": "判断表面 Done 的 root 是否可信完成，并定位返工责任和证据",
  "information_conflicts": ["C-001", "C-002", "C-003"],
  "evidence_priorities": ["E-002", "E-003", "E-005", "E-007"],
  "narrative_hypothesis": "先把表面状态与可信结论并置，再按证据链解释为何必须返工，可以最快消除 Done 的误导",
  "form_rationale": "案例的核心像一份互相矛盾的案件卷宗，因此用情况、冲突、判定、证据链和处置组织阅读",
  "visual_system": "编辑部案件 brief；纸张感中性色、单一警示红、强标题、旁注和证据编号，不使用 dashboard 卡片阵列",
  "discarded_alternatives": ["把 issue 状态放入矩阵", "按时间顺序平铺全部日志"],
  "assumptions": ["读者先需要结论，再决定是否展开原始评论", "Linear 链接只作为证据入口，不承担页面视觉"]
}
```

- [ ] **Step 2：使用独立设计上下文生成完整 HTML**

执行时只读取以下三个文件，不读取 `decision-memo` 或 `review-narrative`：

```text
.symphony/report-design-spike/yqe-134/report_context.json
.symphony/report-design-spike/yqe-134/design-input.md
.symphony/report-design-spike/yqe-134/case-brief/report_brief.json
```

使用 `huashu-design` 生成完整 `index.html`。页面开头用 HTML 注释记录 assumptions、reasoning 和事实边界。必须包含：

1. 首屏并置“表面状态 Done”和“可信结论 needs_rework”。
2. 用一句完整判断解释不能视为可信完成。
3. 用 E-002、E-003、E-005 形成连续证据链。
4. 明确 YQE-143 Done 表示审查任务完成，不表示审查通过。
5. 提供四条 required actions。
6. 折叠原始 Issue Result 摘要和状态历史。
7. 证据入口链接到三个 Linear issue。

不得复制旧 `yqe-134-huashu/index.html` 的 CSS 或整体骨架；可以把它作为早期案件式假设的证据，但本候选必须从共享事实包重新设计。

- [ ] **Step 3：写摘要、manifest 和待评审表**

创建 `summary.md`：

```markdown
# YQE-134 案件 brief 摘要

- 判断：当前不能把 YQE-134 视为可信完成，应进入 needs_rework。
- 冲突：YQE-142 自报实现完成，但 YQE-143 证明核心函数和链接渲染不存在。
- 状态解释：YQE-143 的 Done 只表示审查任务结束，其 outcome 是 fail / needs_rework。
- 动作：重新激活交付、补齐实现或反证、重跑测试、重新独立审查。
- 主报告：`index.html`
```

创建 `manifest.json`：

```json
{
  "schema_version": 1,
  "case_id": "YQE-134",
  "variant": "case-brief",
  "context_path": "../report_context.json",
  "brief_path": "report_brief.json",
  "html_path": "index.html",
  "summary_path": "summary.md",
  "review_path": "review.md",
  "desktop_screenshot": "screenshot.png",
  "mobile_screenshot": "screenshot-mobile.png",
  "generator": "huashu-design-guided-manual-spike",
  "status": "candidate"
}
```

创建 `review.md`：

```markdown
# YQE-134 案件 brief 人工评审

评审状态：待用户评审

## 1 到 3 分钟复述

- 能否说出真实结论，而不是只复述 Done：未评审
- 能否说明结论为什么可信：未评审
- 能否定位最关键证据：未评审
- 能否说出谁需要做什么：未评审
- 能否识别剩余不确定性：未评审

## 设计判断

- 保留项：待用户评审
- 阻断项：待用户评审
- 可迁移项：待用户评审
- 不应固化项：待用户评审

## 最终结论

- accepted：未选择
- rejected：未选择
```

- [ ] **Step 4：用 Browser 完成桌面和窄屏验证**

按 `browser:control-in-app-browser` 初始化默认浏览器，打开：

```text
file:///C:/Users/GQY47/coding/Symphony/.symphony/report-design-spike/yqe-134/case-brief/index.html
```

依次验证：

1. 1440 x 900 视口页面非空、首屏判断完整、无控制台错误，保存全页截图为 `screenshot.png`。
2. 390 x 844 视口无横向溢出、文字不重叠、证据可展开，保存全页截图为 `screenshot-mobile.png`。
3. 点击三个 Linear 证据链接，确认 href 分别指向 YQE-134、YQE-142、YQE-143；不要求离开当前测试页完成登录。

- [ ] **Step 5：运行单候选校验并提交**

运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/report_design_spike/verify_first_round.ps1 -CaseDir .symphony/report-design-spike/yqe-134 -Variants case-brief
git add -- .symphony/report-design-spike/yqe-134/case-brief
git diff --cached --check
```

调用仓库 `commit` skill 创建提交，建议 subject：

```text
docs(report): 增加 YQE-134 案件 brief 候选
```

预期：输出 `第一轮技术校验通过：1 个候选`；提交只包含 `case-brief`。

---

### Task 4：制作决策 memo 候选

**文件：**

- 创建：`.symphony/report-design-spike/yqe-134/decision-memo/report_brief.json`
- 创建：`.symphony/report-design-spike/yqe-134/decision-memo/index.html`
- 创建：`.symphony/report-design-spike/yqe-134/decision-memo/summary.md`
- 创建：`.symphony/report-design-spike/yqe-134/decision-memo/manifest.json`
- 创建：`.symphony/report-design-spike/yqe-134/decision-memo/screenshot.png`
- 创建：`.symphony/report-design-spike/yqe-134/decision-memo/screenshot-mobile.png`
- 创建：`.symphony/report-design-spike/yqe-134/decision-memo/review.md`

- [ ] **Step 1：写决策 memo 的设计判断**

创建 `report_brief.json`：

```json
{
  "schema_version": 1,
  "case_id": "YQE-134",
  "audience": "workflow owner",
  "decision_to_enable": "决定接受完成、要求返工或请求人工调查中的哪一种动作",
  "information_conflicts": ["C-001", "C-002", "C-003"],
  "evidence_priorities": ["E-001", "E-002", "E-003", "E-006"],
  "narrative_hypothesis": "把接受完成和要求返工作为两个可检验选项，用同一组判据逐项排除错误选项，可以让 owner 看见判断过程",
  "form_rationale": "用户面对的是一个需要立即作出的完成决策，而不是要阅读完整案件史，因此用决策问题、判据、选项、推理和建议组织页面",
  "visual_system": "克制的决策 memo；宽页边距、纵向推理线、黑白正文与琥珀警示，不使用案件 brief 的左右卷宗构图",
  "discarded_alternatives": ["直接宣布 needs_rework 而不展示判据", "用状态时间线代替决策过程"],
  "assumptions": ["读者希望知道为什么拒绝 Done，而不只需要最终标签", "两种主要选项足以覆盖当前证据"]
}
```

- [ ] **Step 2：使用独立设计上下文生成完整 HTML**

只读取共享事实包、共同设计输入和本目录 `report_brief.json`，不得读取另两版 HTML 或截图。使用 `huashu-design` 生成完整 `index.html`，必须包含：

1. 唯一决策问题：“是否接受 YQE-134 为可信完成？”
2. “接受完成”和“要求返工”两个选项，不把状态矩阵作为主体。
3. 至少四个判据：实现存在、测试可信、独立审查通过、状态语义一致。
4. 每个判据引用 E-001、E-002、E-003 或 E-006。
5. 明确排除“接受完成”，推荐“要求返工”。
6. 最后给出执行顺序和重新接受的条件。

首屏、内容顺序和证据组织必须与案件 brief 不同。

- [ ] **Step 3：写摘要、manifest 和待评审表**

`summary.md`：

```markdown
# YQE-134 决策 memo 摘要

- 决策：不接受当前完成状态，选择要求返工。
- 判据：实现存在、测试可信、独立审查通过、状态语义一致。
- 结果：当前证据未满足前三项，Done 也与 review outcome 冲突。
- 重新接受条件：补齐实现或反证、重跑测试、独立审查通过。
- 主报告：`index.html`
```

`manifest.json`：

```json
{
  "schema_version": 1,
  "case_id": "YQE-134",
  "variant": "decision-memo",
  "context_path": "../report_context.json",
  "brief_path": "report_brief.json",
  "html_path": "index.html",
  "summary_path": "summary.md",
  "review_path": "review.md",
  "desktop_screenshot": "screenshot.png",
  "mobile_screenshot": "screenshot-mobile.png",
  "generator": "huashu-design-guided-manual-spike",
  "status": "candidate"
}
```

`review.md`：

```markdown
# YQE-134 决策 memo 人工评审

评审状态：待用户评审

## 1 到 3 分钟复述

- 能否说出需要做出的决定：未评审
- 能否说出拒绝 Done 的判据：未评审
- 能否定位最关键证据：未评审
- 能否说出重新接受的条件：未评审
- 能否识别剩余不确定性：未评审

## 设计判断

- 保留项：待用户评审
- 阻断项：待用户评审
- 可迁移项：待用户评审
- 不应固化项：待用户评审

## 最终结论

- accepted：未选择
- rejected：未选择
```

- [ ] **Step 4：用 Browser 完成桌面和窄屏验证**

打开：

```text
file:///C:/Users/GQY47/coding/Symphony/.symphony/report-design-spike/yqe-134/decision-memo/index.html
```

在 1440 x 900 和 390 x 844 视口验证页面非空、无重叠、决策和推荐在首屏可见、无控制台错误，分别保存 `screenshot.png` 和 `screenshot-mobile.png`。点击证据入口确认 href 正确。

- [ ] **Step 5：运行单候选校验并提交**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/report_design_spike/verify_first_round.ps1 -CaseDir .symphony/report-design-spike/yqe-134 -Variants decision-memo
git add -- .symphony/report-design-spike/yqe-134/decision-memo
git diff --cached --check
```

调用仓库 `commit` skill 创建提交，建议 subject：

```text
docs(report): 增加 YQE-134 决策 memo 候选
```

预期：技术校验通过；提交只包含 `decision-memo`。

---

### Task 5：制作审查叙事候选

**文件：**

- 创建：`.symphony/report-design-spike/yqe-134/review-narrative/report_brief.json`
- 创建：`.symphony/report-design-spike/yqe-134/review-narrative/index.html`
- 创建：`.symphony/report-design-spike/yqe-134/review-narrative/summary.md`
- 创建：`.symphony/report-design-spike/yqe-134/review-narrative/manifest.json`
- 创建：`.symphony/report-design-spike/yqe-134/review-narrative/screenshot.png`
- 创建：`.symphony/report-design-spike/yqe-134/review-narrative/screenshot-mobile.png`
- 创建：`.symphony/report-design-spike/yqe-134/review-narrative/review.md`

- [ ] **Step 1：写审查叙事的设计判断**

创建 `report_brief.json`：

```json
{
  "schema_version": 1,
  "case_id": "YQE-134",
  "audience": "workflow owner",
  "decision_to_enable": "理解最终审查的阻断 finding、影响、证据和重新通过条件",
  "information_conflicts": ["C-001", "C-002", "C-003"],
  "evidence_priorities": ["E-003", "E-004", "E-005", "E-006"],
  "narrative_hypothesis": "findings first 可以把核心交付缺失作为唯一阻断项，再用代码、渲染和测试证据逐层证明，减少状态噪声",
  "form_rationale": "案例最强事实来自 final review 的代码审查，因此用 finding、影响、主张、反证和通过条件组织页面",
  "visual_system": "审查批注式叙事；高密度排印、行号感证据边栏、严重性红和通过条件绿，不使用 memo 的选项推理线",
  "discarded_alternatives": ["按 issue 分三栏", "把所有审查 evidence 做成无层级列表"],
  "assumptions": ["读者接受 findings-first 的工程审查语言", "一个 P0 阻断 finding 比多个状态摘要更准确"]
}
```

- [ ] **Step 2：使用独立设计上下文生成完整 HTML**

只读取共享事实包、共同设计输入和本目录 `report_brief.json`，不得读取另两版 HTML 或截图。使用 `huashu-design` 生成完整 `index.html`，必须包含：

1. 首屏只有一个阻断 finding：核心链接化交付不存在。
2. finding 的影响：root 的 Done 不可信，后续状态和通知会误导。
3. 上游主张：YQE-142 自报三个函数存在且测试通过。
4. 独立反证：E-003、E-004、E-005、E-006。
5. “审查任务完成”和“实现通过”语义分离。
6. 明确列出重新通过条件，而不是泛泛写“修复后重试”。

首屏、内容顺序和证据组织必须与案件 brief、决策 memo 不同。

- [ ] **Step 3：写摘要、manifest 和待评审表**

`summary.md`：

```markdown
# YQE-134 审查叙事摘要

- 阻断 finding：核心 issue identifier 链接化交付不存在。
- 影响：root 的 Done 不能作为可信完成，继续下游流程会传播错误状态。
- 反证：目标函数 grep 为 0、关键渲染点仍为纯文本、测试引用未定义函数。
- 通过条件：实现存在、目标测试真实通过、独立审查接受。
- 主报告：`index.html`
```

`manifest.json`：

```json
{
  "schema_version": 1,
  "case_id": "YQE-134",
  "variant": "review-narrative",
  "context_path": "../report_context.json",
  "brief_path": "report_brief.json",
  "html_path": "index.html",
  "summary_path": "summary.md",
  "review_path": "review.md",
  "desktop_screenshot": "screenshot.png",
  "mobile_screenshot": "screenshot-mobile.png",
  "generator": "huashu-design-guided-manual-spike",
  "status": "candidate"
}
```

`review.md`：

```markdown
# YQE-134 审查叙事人工评审

评审状态：待用户评审

## 1 到 3 分钟复述

- 能否说出唯一阻断 finding：未评审
- 能否解释 finding 的影响：未评审
- 能否区分上游主张和独立反证：未评审
- 能否说出重新通过条件：未评审
- 能否识别剩余不确定性：未评审

## 设计判断

- 保留项：待用户评审
- 阻断项：待用户评审
- 可迁移项：待用户评审
- 不应固化项：待用户评审

## 最终结论

- accepted：未选择
- rejected：未选择
```

- [ ] **Step 4：用 Browser 完成桌面和窄屏验证**

打开：

```text
file:///C:/Users/GQY47/coding/Symphony/.symphony/report-design-spike/yqe-134/review-narrative/index.html
```

在 1440 x 900 和 390 x 844 视口验证页面非空、无重叠、阻断 finding 和影响在首屏可见、无控制台错误，分别保存 `screenshot.png` 和 `screenshot-mobile.png`。点击证据入口确认 href 正确。

- [ ] **Step 5：运行单候选校验并提交**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/report_design_spike/verify_first_round.ps1 -CaseDir .symphony/report-design-spike/yqe-134 -Variants review-narrative
git add -- .symphony/report-design-spike/yqe-134/review-narrative
git diff --cached --check
```

调用仓库 `commit` skill 创建提交，建议 subject：

```text
docs(report): 增加 YQE-134 审查叙事候选
```

预期：技术校验通过；提交只包含 `review-narrative`。

---

### Task 6：制作三版评审入口并执行最终门禁

**文件：**

- 创建：`.symphony/report-design-spike/yqe-134/review-index.html`
- 创建：`.symphony/report-design-spike/yqe-134/review-index.png`
- 创建：`.symphony/report-design-spike/yqe-134/review-index-mobile.png`

- [ ] **Step 1：创建完整评审入口**

创建 `review-index.html`：

```html
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>YQE-134 同案三解</title>
  <style>
    :root {
      color-scheme: light;
      --ink: #181817;
      --muted: #68645d;
      --paper: #f5f3ee;
      --line: #cbc5ba;
      --accent: #a93428;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: var(--paper);
      color: var(--ink);
      font-family: "Microsoft YaHei", "PingFang SC", sans-serif;
      letter-spacing: 0;
    }
    header, main, footer {
      width: min(1500px, calc(100% - 40px));
      margin-inline: auto;
    }
    header {
      padding: 44px 0 28px;
      border-bottom: 1px solid var(--line);
    }
    .eyebrow {
      margin: 0 0 10px;
      color: var(--accent);
      font-size: 13px;
      font-weight: 700;
      text-transform: uppercase;
    }
    h1 {
      margin: 0;
      max-width: 900px;
      font-family: SimSun, "Songti SC", serif;
      font-size: 56px;
      line-height: 1.06;
    }
    .lede {
      max-width: 760px;
      margin: 18px 0 0;
      color: var(--muted);
      font-size: 16px;
      line-height: 1.7;
    }
    main {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 0;
      padding: 34px 0 50px;
      border-bottom: 1px solid var(--line);
    }
    article {
      min-width: 0;
      padding: 0 24px 28px;
      border-left: 1px solid var(--line);
    }
    article:first-child { border-left: 0; padding-left: 0; }
    article:last-child { padding-right: 0; }
    figure { margin: 0; }
    img {
      display: block;
      width: 100%;
      aspect-ratio: 16 / 10;
      object-fit: cover;
      object-position: top;
      border: 1px solid var(--line);
      background: white;
    }
    .number {
      display: block;
      margin: 22px 0 8px;
      color: var(--accent);
      font: 700 12px/1 "Consolas", monospace;
    }
    h2 {
      margin: 0;
      font-family: SimSun, "Songti SC", serif;
      font-size: 28px;
      line-height: 1.2;
    }
    .question {
      min-height: 72px;
      margin: 16px 0;
      color: var(--muted);
      font-size: 15px;
      line-height: 1.6;
    }
    dl {
      display: grid;
      grid-template-columns: 76px 1fr;
      gap: 8px 12px;
      margin: 0 0 22px;
      font-size: 14px;
      line-height: 1.5;
    }
    dt { color: var(--muted); }
    dd { margin: 0; }
    a {
      display: inline-block;
      color: var(--ink);
      font-weight: 700;
      text-underline-offset: 4px;
    }
    footer {
      padding: 22px 0 36px;
      color: var(--muted);
      font-size: 13px;
    }
    @media (max-width: 900px) {
      header, main, footer { width: min(100% - 28px, 680px); }
      h1 { font-size: 36px; }
      main { grid-template-columns: 1fr; padding-top: 18px; }
      article, article:first-child, article:last-child {
        padding: 24px 0 30px;
        border-left: 0;
        border-top: 1px solid var(--line);
      }
      article:first-child { border-top: 0; }
      .question { min-height: 0; }
    }
  </style>
</head>
<body>
  <header>
    <p class="eyebrow">YQE-134 · report design pattern spike</p>
    <h1>同一组事实，三种判断路径</h1>
    <p class="lede">三版共享相同 Linear 事实，只改变叙事角色、信息顺序和证据组织。它们都是 candidate，不代表已经通过人工可读性门禁。</p>
  </header>
  <main>
    <article>
      <figure><img src="case-brief/screenshot.png" alt="案件 brief 桌面截图"></figure>
      <span class="number">01 / CASE BRIEF</span>
      <h2>案件 brief</h2>
      <p class="question">先揭示表面 Done 与真实 needs_rework 的冲突，再用证据链给出处置。</p>
      <dl>
        <dt>首要问题</dt><dd>发生了什么，为什么不能结案？</dd>
        <dt>证据组织</dt><dd>冲突 → 判定 → 证据链</dd>
        <dt>最终动作</dt><dd>恢复 active 并返工</dd>
      </dl>
      <a href="case-brief/index.html">打开完整候选</a>
    </article>
    <article>
      <figure><img src="decision-memo/screenshot.png" alt="决策 memo 桌面截图"></figure>
      <span class="number">02 / DECISION MEMO</span>
      <h2>决策 memo</h2>
      <p class="question">围绕是否接受完成这一决定，用共同判据排除错误选项。</p>
      <dl>
        <dt>首要问题</dt><dd>接受完成还是要求返工？</dd>
        <dt>证据组织</dt><dd>选项 → 判据 → 推理</dd>
        <dt>最终动作</dt><dd>拒绝接受，等待重审</dd>
      </dl>
      <a href="decision-memo/index.html">打开完整候选</a>
    </article>
    <article>
      <figure><img src="review-narrative/screenshot.png" alt="审查叙事桌面截图"></figure>
      <span class="number">03 / REVIEW NARRATIVE</span>
      <h2>审查叙事</h2>
      <p class="question">把核心交付缺失作为阻断 finding，用独立反证说明影响和通过条件。</p>
      <dl>
        <dt>首要问题</dt><dd>哪个 finding 阻断了通过？</dd>
        <dt>证据组织</dt><dd>finding → 反证 → 影响</dd>
        <dt>最终动作</dt><dd>满足通过条件后重审</dd>
      </dl>
      <a href="review-narrative/index.html">打开完整候选</a>
    </article>
  </main>
  <footer>事实快照：2026-07-13 · 当前阶段：第一轮人工选型</footer>
</body>
</html>
```

- [ ] **Step 2：用 Browser 验证评审入口并截图**

打开：

```text
file:///C:/Users/GQY47/coding/Symphony/.symphony/report-design-spike/yqe-134/review-index.html
```

验证：

1. 1440 x 900 下三列截图和文字没有溢出，保存全页 `review-index.png`。
2. 390 x 844 下三版按顺序单列显示，保存全页 `review-index-mobile.png`。
3. 三个“打开完整候选”链接都能进入对应页面。
4. 浏览器控制台没有 error。

- [ ] **Step 3：运行第一轮完整技术门禁**

运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/report_design_spike/verify_first_round_tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/report_design_spike/verify_first_round.ps1 -CaseDir .symphony/report-design-spike/yqe-134
rg -n -i "LINEAR_API_KEY|Bearer |api[_-]?key" .symphony/report-design-spike/yqe-134
git diff --check
```

预期：

```text
verify_first_round_tests：3/3 通过
第一轮技术校验通过：3 个候选
敏感信息扫描无匹配
git diff --check 无输出
```

- [ ] **Step 4：肉眼执行跨版本设计检查**

同时打开三张桌面截图，逐项确认：

1. 三版首屏构图不同。
2. 三版信息顺序不同。
3. 三版证据组织不同。
4. 三版都能在首屏看见真实判断、Done 不可信的原因和下一步。
5. 没有一版退化成 dashboard、状态矩阵或同骨架换肤。
6. 没有文字重叠、按钮挤压、最长 issue 标题溢出或证据遮挡。

任何一项不满足时，回到对应候选任务重做，不降低为“只换色板”的轻量变体。

- [ ] **Step 5：提交评审入口**

运行：

```powershell
git add -- .symphony/report-design-spike/yqe-134/review-index.html .symphony/report-design-spike/yqe-134/review-index.png .symphony/report-design-spike/yqe-134/review-index-mobile.png
git diff --cached --check
```

调用仓库 `commit` skill 创建提交，建议 subject：

```text
docs(report): 增加 YQE-134 三版评审入口
```

预期：提交只包含评审入口和两张截图。

- [ ] **Step 6：交给用户执行人工门禁并停止**

向用户提供：

```text
C:\Users\GQY47\coding\Symphony\.symphony\report-design-spike\yqe-134\review-index.html
```

同时展示三张桌面截图。请用户对每版给出：

1. `accepted` 或 `rejected`；
2. 要保留的设计判断；
3. 阻断使用的问题；
4. 可以迁移的部分；
5. 不应固化的个案设计；
6. 是否要混合两版后再评审。

在用户明确接受至少一个 YQE-134 候选前，不执行第二轮对照案例，不编写 `engineering-html-report` 生产 skill，不恢复 renderer。

---

## 计划自审

### Spec 覆盖

1. 真实事实输入由 Task 2 的 Linear 只读复核和 `report_context.json` 覆盖。
2. 同案三解由 Task 3、Task 4、Task 5 覆盖。
3. 三版共享事实、独立 form 由共同设计输入和隔离读取规则覆盖。
4. `report_brief.json` 的新语义由三个完整 brief 覆盖。
5. 自包含、桌面和窄屏、控制台、截图验证由 Task 1 和每版 Browser 步骤覆盖。
6. 人工可读性门禁由 Task 6 的评审入口和停止条件覆盖。
7. 旧 renderer 冻结由范围边界和精确暂存命令覆盖。
8. 第二轮迁移、golden 抽象和生产 skill 明确留到用户完成第一轮评审之后。

### 占位符检查

计划中的“待用户评审”“未评审”“未选择”是候选 artifact 的真实初始状态，不是未定义实现。代码、JSON、路径、命令、预期输出、候选内容和失败条件均已给出；HTML form 保持开放是 spec 明确批准的设计边界。

### 类型和命名一致性

1. 三版目录名与 `manifest.variant` 一致：`case-brief`、`decision-memo`、`review-narrative`。
2. 三份 manifest 都引用 `../report_context.json`。
3. 三份 brief 都使用 spec 定义的 11 个字段。
4. verifier 的默认候选名、计划目录名和评审入口链接完全一致。
5. 桌面截图统一为 `screenshot.png`，窄屏截图统一为 `screenshot-mobile.png`。
6. 候选状态统一为 `candidate`，人工评审前不写 `accepted`。
