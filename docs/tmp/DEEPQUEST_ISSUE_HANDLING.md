# DeepQuest Issue 处理问题交接说明

## 问题描述

在 DeepQuest 项目中创建的 Linear issue 一直未被 Symphony 正确执行。

## 已完成的修复

### 1. 多项目配置修复 ✅

**问题**：Symphony 使用 `WORKFLOW.local.md` 启动，但该文件只有单项目配置：
```yaml
tracker:
  project_slug: "96f5ac7500e2"  # 只有 symphony 项目
```

**修复**：更新 `WORKFLOW.local.md` 为多项目配置：
```yaml
tracker:
  kind: linear
  projects:
    symphony:
      slug: "96f5ac7500e2"
      repository: "https://github.com/openai/symphony"
    deepquest:
      slug: "04b9404aad35"
      repository:
        - "/mnt/c/Users/GQY47/coding/DeepQuest"
        - "https://github.com/GQY-479/DeepQuest"
```

**验证**：重启 Symphony 后日志显示：
```
Projects: deepquest=https://linear.app/project/04b9404aad35/issues, symphony=https://linear.app/project/96f5ac7500e2/issues
```

## 待排查问题

### 2. Assignee 过滤问题 ⚠️

**当前配置**：`assignee: "me"`

**影响**：Symphony 只会处理分配给当前 Linear 用户的 issue。

**检查方法**：
1. 确认 DeepQuest 项目中的 issue 是否已分配给你
2. 或者临时移除 assignee 过滤（不推荐用于生产环境）

**临时解决方案**：在 `WORKFLOW.local.md` 中注释掉 assignee 行：
```yaml
# assignee: "me"
```

### 3. Linear API 权限问题 ⚠️

**症状**：无法在 WSL 中直接查询 Linear API

**检查方法**：
1. 确认 `LINEAR_API_KEY` 环境变量是否设置
2. 确认 API key 是否有权限访问 DeepQuest 项目
3. 在 Windows PowerShell 中运行：
   ```powershell
   echo $env:LINEAR_API_KEY
   ```

### 4. Issue 状态问题 ⚠️

**要求**：issue 必须处于以下状态才会被处理：
- `Todo`
- `In Progress`
- `Merging`
- `Rework`

**检查方法**：
1. 确认 DeepQuest 中的 issue 状态是否为上述之一
2. 如果是 `Backlog` 状态，需要手动移动到 `Todo`

### 5. Labels 要求

**当前配置**：`required_labels: []`（无特殊要求）

**影响**：如果后续添加了 required_labels，issue 必须包含对应标签才会被处理。

## 重启 Symphony 的方法

### 方法 1：通过 WSL（推荐）
```bash
# 停止现有进程
kill $(lsof -t -i :4000)

# 启动 Symphony
cd /mnt/c/Users/GQY47/coding/Symphony/elixir
nohup mise exec -- ./bin/symphony ./WORKFLOW.local.md --port 4000 --i-understand-that-this-will-be-running-without-the-usual-guardrails > /tmp/symphony.log 2>&1 &
```

### 方法 2：通过 Windows PowerShell
```powershell
cd C:\Users\GQY47\coding\Symphony\elixir
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-local.ps1
```

## 验证步骤

1. **检查 Symphony 状态**：
   ```bash
   curl -s http://localhost:4000/ | grep -E "deepquest|DeepQuest"
   ```

2. **查看实时日志**：
   ```bash
   tail -f /tmp/symphony.log
   ```

3. **检查 Dashboard**：
   访问 http://127.0.0.1:4000/ 查看是否有 DeepQuest 的 issue 被捕获

## 下一步行动

1. **立即**：检查 DeepQuest 项目中的 issue 是否分配给了你
2. **立即**：确认 issue 状态是否为 `Todo` 或其他 active 状态
3. **可选**：临时移除 `assignee: "me"` 配置测试是否能捕获 issue
4. **验证**：重启 Symphony 后观察 Dashboard 是否显示 DeepQuest issue

## 相关文件

- `WORKFLOW.local.md` — 本地工作流配置（已更新）
- `WORKFLOW.md` — 主工作流配置（多项目配置参考）
- `/tmp/symphony.log` — Symphony 运行日志
- `elixir/symphony-local-4002.out.log` — 详细输出日志

---

**最后更新**：2026-06-26
**状态**：配置已修复，待验证 assignee 过滤和 issue 状态
