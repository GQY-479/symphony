# Root Workflow 看板改版实施计划

> **给 agentic workers：** 必须使用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans` 按任务执行。本计划使用 checkbox（`- [ ]`）跟踪进度。

**目标：** 实现以 root workflow 为主轴的新版观测看板：首页可快速扫描全局，详情页可查看单个 root workflow 的轻量链路。

**架构：** 数据整理放在 `SymphonyElixirWeb.Presenter`，LiveView 只消费已经整理好的投影。首页消费 `payload.workflows` 和 `payload.attention_items`；详情页通过 `Presenter.workflow_payload/3` 合并 runtime snapshot 和可用的 workflow registry 摘要。

**技术栈：** Elixir 1.19、Phoenix LiveView、ExUnit、现有 `elixir/priv/static/dashboard.css`。

---

## 文件结构

- 修改 `elixir/lib/symphony_elixir_web/presenter.ex`：新增 workflow 聚合投影和详情投影，保持现有 API 字段兼容。
- 修改 `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`：把首页改为三栏 root workflow 作战室。
- 新增 `elixir/lib/symphony_elixir_web/live/workflow_live.ex`：展示单个 root workflow 详情。
- 修改 `elixir/lib/symphony_elixir_web/router.ex`：增加 `/workflows/:root_identifier` 路由。
- 修改 `elixir/priv/static/dashboard.css`：改成更紧凑的运维扫描布局。
- 新增测试：
  - `elixir/test/symphony_elixir/presenter_workflow_test.exs`
  - `elixir/test/symphony_elixir/dashboard_live_test.exs`

## 任务 1：Presenter 首页 workflow 聚合

**文件：**
- 修改：`elixir/lib/symphony_elixir_web/presenter.ex`
- 新增：`elixir/test/symphony_elixir/presenter_workflow_test.exs`

- [ ] **步骤 1：先写失败测试**

新增 `PresenterWorkflowTest`，覆盖两个行为：

```elixir
test "state_payload groups runtime entries by workflow root" do
  snapshot = %{
    running: [running_entry(%{identifier: "SYM-102", workflow_root_issue_id: "SYM-100", workflow_phase: :execution})],
    retrying: [retry_entry(%{identifier: "SYM-103", workflow_root_issue_id: "SYM-100", workflow_phase: :review, attempt: 2})],
    blocked: [blocked_entry(%{identifier: "SYM-101", workflow_root_issue_id: "SYM-100", workflow_phase: :planning, workflow_blocked_reason: "needs human input"})],
    codex_totals: %{input_tokens: 1_000, output_tokens: 200, total_tokens: 1_200, seconds_running: 42},
    rate_limits: nil
  }

  payload = Presenter.state_payload({:snapshot, snapshot}, 1_000)

  assert [%{root_issue_identifier: "SYM-100"} = workflow] = payload.workflows
  assert workflow.status == "blocked"
  assert workflow.counts.running == 1
  assert workflow.counts.retrying == 1
  assert workflow.counts.blocked == 1
  assert [%{kind: "blocked", issue_identifier: "SYM-101"}] = workflow.attention_items
  assert [%{root_issue_identifier: "SYM-100", issue_identifier: "SYM-101"}] = payload.attention_items
end

test "state_payload creates direct execution workflow for entries without workflow root" do
  snapshot = %{
    running: [running_entry(%{identifier: "SYM-200", workflow_root_issue_id: nil, workflow_phase: nil})],
    retrying: [],
    blocked: [],
    codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
    rate_limits: nil
  }

  payload = Presenter.state_payload({:snapshot, snapshot}, 1_000)

  assert [%{root_issue_identifier: "SYM-200"} = workflow] = payload.workflows
  assert workflow.status == "direct_execution"
  assert workflow.registry_available? == false
end
```

测试文件内提供 `running_entry/1`、`retry_entry/1`、`blocked_entry/1` helper，字段按现有 runtime entry 结构补齐。

- [ ] **步骤 2：运行测试确认 RED**

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/presenter_workflow_test.exs
```

预期：失败，因为 `state_payload/2` 还不支持 `{:snapshot, snapshot}` 测试入口，也没有 `workflows` 和 `attention_items`。

- [ ] **步骤 3：实现最小 Presenter 聚合**

在 `Presenter` 中：

- 把 `state_payload/2` 的 `@spec` 扩展为支持 `{:snapshot, map()}`。
- 新增 `snapshot_for/2` 私有 helper。
- 成功 snapshot 分支先生成 `running/retrying/blocked` payload，再生成：
  - `workflows: workflow_payloads(running, retrying, blocked)`
  - `attention_items: attention_items(workflows)`

新增私有 helper：

- `workflow_payloads/3`
- `workflow_root_identifier/1`
- `workflow_status/3`
- `phase_summary/1`
- `workflow_attention_items/3`
- `attention_items/1`
- `recent_event/1`
- `workflow_tokens/1`
- `workflow_sort_key/1`

实现原则：

- 有 `workflow_root_issue_id` 就按它聚合。
- 没有 root 的旧式 session 用自身 `issue_identifier` 作为 pseudo workflow。
- `blocked` 优先级高于 `running`，`running` 高于 `retrying`。
- 顶层 attention inbox 先显示 blocked，再显示高 attempt retry。

- [ ] **步骤 4：运行测试确认 GREEN**

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/presenter_workflow_test.exs
```

预期：通过。

- [ ] **步骤 5：运行 public spec 检查**

```bash
cd elixir
mise exec -- mix specs.check
```

预期：通过。若新增 public `def` 缺 `@spec`，补齐后重跑。

- [ ] **步骤 6：提交任务 1**

```bash
git add elixir/lib/symphony_elixir_web/presenter.ex elixir/test/symphony_elixir/presenter_workflow_test.exs
git commit -m "feat(dashboard): add workflow presenter projection"
```

## 任务 2：Presenter workflow 详情投影

**文件：**
- 修改：`elixir/lib/symphony_elixir_web/presenter.ex`
- 修改：`elixir/test/symphony_elixir/presenter_workflow_test.exs`

- [ ] **步骤 1：先写失败测试**

在 `PresenterWorkflowTest` 增加：

```elixir
test "workflow_payload returns registry nodes for a root workflow" do
  with_workflow_registry("SYM-300", %{
    "root_issue_id" => "root-issue-id",
    "root_issue_identifier" => "SYM-300",
    "root_title" => "Ship dashboard redesign",
    "status" => "running",
    "nodes" => %{
      "implementation" => %{
        "issue_id" => "issue-impl",
        "issue_identifier" => "SYM-301",
        "title" => "Implement dashboard",
        "task_type" => "implementation",
        "status" => "completed",
        "completion_packet" => %{"summary" => "Dashboard finished", "evidence" => ["mix test"]}
      },
      "review" => %{
        "issue_id" => "issue-review",
        "issue_identifier" => "SYM-302",
        "title" => "Review dashboard",
        "task_type" => "review",
        "status" => "ready",
        "review_summary" => "Needs copy cleanup"
      }
    },
    "edges" => [%{"from" => "implementation", "to" => "review", "type" => "blocks"}]
  }, fn ->
    snapshot = %{
      running: [running_entry(%{identifier: "SYM-302", workflow_root_issue_id: "SYM-300", workflow_phase: :review})],
      retrying: [],
      blocked: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }

    assert {:ok, payload} = Presenter.workflow_payload("SYM-300", {:snapshot, snapshot}, 1_000)
    assert payload.registry_available? == true
    assert payload.root_title == "Ship dashboard redesign"
    assert [%{node_key: "implementation"}, %{node_key: "review"}] = payload.nodes
    assert [%{from: "implementation", to: "review", type: "blocks"}] = payload.edges
  end)
end

test "workflow_payload falls back to runtime entries when registry is unavailable" do
  snapshot = %{
    running: [running_entry(%{identifier: "SYM-401", workflow_root_issue_id: "SYM-400"})],
    retrying: [],
    blocked: [],
    codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
    rate_limits: nil
  }

  assert {:ok, payload} = Presenter.workflow_payload("SYM-400", {:snapshot, snapshot}, 1_000)
  assert payload.registry_available? == false
  assert payload.nodes == []
  assert [%{issue_identifier: "SYM-401"}] = payload.runtime_entries
end
```

新增 `with_workflow_registry/3` helper：在临时 workspace root 下写入 `.symphony/workflows/<root>.json`，测试结束后恢复 `SYMPHONY_WORKSPACE_ROOT` 并删除临时目录。

- [ ] **步骤 2：运行测试确认 RED**

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/presenter_workflow_test.exs
```

预期：失败，因为 `Presenter.workflow_payload/3` 还不存在。

- [ ] **步骤 3：实现详情投影**

在 `Presenter` 新增：

```elixir
@spec workflow_payload(String.t(), GenServer.name() | {:snapshot, map()}, timeout()) ::
        {:ok, map()} | {:error, :workflow_not_found}
```

实现要点：

- 从 snapshot 复用任务 1 的 `workflow_payloads/3` 聚合。
- 优先读取 registry 文件：
  - 路径：`Config.settings!().workspace.root/.symphony/workflows/<root_identifier>.json`
  - 使用 `Jason.decode/1`。
- registry 存在时返回：
  - `root_issue_identifier`
  - `root_issue_id`
  - `root_title`
  - `status`
  - `registry_available?: true`
  - `nodes`
  - `edges`
  - `runtime_entries`
  - `attention_items`
- registry 不存在但 snapshot 有 runtime entries 时返回 fallback payload。
- registry 和 runtime 都没有时返回 `{:error, :workflow_not_found}`。

registry node 投影只暴露看板需要的字段：

- `node_key`
- `issue_id`
- `issue_identifier`
- `title`
- `task_type`
- `status`
- `workflow_semantics`
- `completion_summary`
- `evidence_count`
- `review_summary`
- `blocked_reason`

- [ ] **步骤 4：运行测试确认 GREEN**

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/presenter_workflow_test.exs
```

预期：通过。

- [ ] **步骤 5：运行 spec 检查**

```bash
cd elixir
mise exec -- mix specs.check
```

预期：通过。

- [ ] **步骤 6：提交任务 2**

```bash
git add elixir/lib/symphony_elixir_web/presenter.ex elixir/test/symphony_elixir/presenter_workflow_test.exs
git commit -m "feat(dashboard): project workflow detail data"
```

## 任务 3：首页 LiveView 改版

**文件：**
- 修改：`elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- 修改：`elixir/priv/static/dashboard.css`
- 新增：`elixir/test/symphony_elixir/dashboard_live_test.exs`

- [ ] **步骤 1：先写失败测试**

新增 `DashboardLiveTest`，构造 `{:snapshot, snapshot}` endpoint 配置后访问 `/`，断言：

- 页面包含 `Root Workflows`
- 页面包含 `SYM-500`
- 页面包含 `execution`
- 页面包含 `Attention Inbox`
- 页面包含 `review needs human`
- 页面包含 `/workflows/SYM-500`

- [ ] **步骤 2：运行测试确认 RED**

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/dashboard_live_test.exs
```

预期：失败，因为旧首页不渲染 workflow 卡片和 attention inbox。

- [ ] **步骤 3：重写 `DashboardLive.render/1` 的成功分支**

保留 snapshot error 分支。成功分支改为：

- 顶部：`Root Workflows` 标题、Live/Offline 状态。
- 指标区：workflow 数量、running、blocked、total tokens。
- 三栏：
  - 左栏 filters：All、Running、Review、Blocked、Retrying。
  - 中栏 workflow 卡片列表。
  - 右栏 attention inbox。

新增 helper：

- `workflow_link/1`
- `phase_label/1`

不要在模板里做复杂数据整理；缺字段说明 presenter 没整理好，应回到 presenter 修。

- [ ] **步骤 4：追加紧凑 CSS**

在 `dashboard.css` 增加：

- `.dashboard-shell-ops`
- `.ops-topbar`
- `.ops-metrics`
- `.ops-grid`
- `.ops-sidebar`
- `.workflow-list`
- `.workflow-card`
- `.attention-panel`
- `.attention-item`
- 小屏幕下三栏折叠为单栏

卡片圆角保持 8px，避免继续扩大旧 hero/card 视觉。

- [ ] **步骤 5：运行测试确认 GREEN**

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/dashboard_live_test.exs
```

预期：通过。

- [ ] **步骤 6：提交任务 3**

```bash
git add elixir/lib/symphony_elixir_web/live/dashboard_live.ex elixir/priv/static/dashboard.css elixir/test/symphony_elixir/dashboard_live_test.exs
git commit -m "feat(dashboard): render root workflow home"
```

## 任务 4：Root workflow 详情页

**文件：**
- 新增：`elixir/lib/symphony_elixir_web/live/workflow_live.ex`
- 修改：`elixir/lib/symphony_elixir_web/router.ex`
- 修改：`elixir/priv/static/dashboard.css`
- 修改：`elixir/test/symphony_elixir/dashboard_live_test.exs`

- [ ] **步骤 1：先写失败测试**

在 `DashboardLiveTest` 增加访问 `/workflows/SYM-600` 的测试，snapshot 中只有 runtime entry，没有 registry。断言：

- 页面包含 `SYM-600`
- 页面包含 `Registry unavailable`
- 页面包含 `SYM-601`
- 页面包含 `execution`

- [ ] **步骤 2：运行测试确认 RED**

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/dashboard_live_test.exs
```

预期：失败，因为路由和 LiveView 还不存在。

- [ ] **步骤 3：增加路由**

在 browser scope 中增加：

```elixir
live("/workflows/:root_identifier", WorkflowLive, :show)
```

必须放在 API catch-all 之前。

- [ ] **步骤 4：新增 `WorkflowLive`**

模块职责：

- `mount/3` 从 params 读取 `root_identifier`。
- 调用 `Presenter.workflow_payload/3`。
- connected 后订阅 `ObservabilityPubSub`。
- 收到 `:observability_updated` 后刷新当前 root payload。
- 渲染：
  - 返回首页链接
  - root workflow header
  - registry unavailable 错误/提示
  - runtime entries
  - registry nodes
  - workflow not found 错误态

项目规则：public callback 用 `@impl true`；其它 public `def` 若有则加 `@spec`。

- [ ] **步骤 5：追加详情页 CSS**

增加：

- `.workflow-detail-shell`
- `.workflow-detail-header`
- `.node-list`
- `.node-row`
- 小屏幕下 node row 折叠为单列

- [ ] **步骤 6：运行测试确认 GREEN**

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/dashboard_live_test.exs
```

预期：通过。

- [ ] **步骤 7：运行 spec 检查**

```bash
cd elixir
mise exec -- mix specs.check
```

预期：通过。

- [ ] **步骤 8：提交任务 4**

```bash
git add elixir/lib/symphony_elixir_web/live/workflow_live.ex elixir/lib/symphony_elixir_web/router.ex elixir/priv/static/dashboard.css elixir/test/symphony_elixir/dashboard_live_test.exs
git commit -m "feat(dashboard): add workflow detail view"
```

## 任务 5：降级、空态与兼容性

**文件：**
- 修改：`elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- 修改：`elixir/priv/static/dashboard.css`
- 修改：`elixir/test/symphony_elixir/dashboard_live_test.exs`

- [ ] **步骤 1：补空态测试**

在 `DashboardLiveTest` 增加空 snapshot：

- `running: []`
- `retrying: []`
- `blocked: []`

断言首页包含：

- `No active root workflows`
- `No operator action needed`

- [ ] **步骤 2：运行测试确认 RED 或确认已 GREEN**

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/dashboard_live_test.exs
```

如果已经通过，继续下一步；如果失败，修正空态文案或 nil guard。

- [ ] **步骤 3：修正空态和 nil guard**

所有 `@payload.workflows`、`@payload.attention_items` 使用都应由 presenter 保证存在。模板只处理空列表，不在模板里拼凑数据。

- [ ] **步骤 4：运行 focused web 测试**

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/presenter_workflow_test.exs test/symphony_elixir/dashboard_live_test.exs
```

预期：通过。

- [ ] **步骤 5：运行 API 兼容测试**

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/extensions_test.exs
```

预期：通过。若出现无关失败，先判断是否由本分支导致，不做无关修复。

- [ ] **步骤 6：提交任务 5**

```bash
git add elixir/lib/symphony_elixir_web/live/dashboard_live.ex elixir/priv/static/dashboard.css elixir/test/symphony_elixir/dashboard_live_test.exs
git commit -m "fix(dashboard): polish workflow dashboard states"
```

## 任务 6：最终验证

**文件：**
- 如果实现偏离设计，仅更新设计 spec 或 Elixir README 中受影响的段落。

- [ ] **步骤 1：格式化**

```bash
cd elixir
mise exec -- mix format
```

预期：退出码 0。

- [ ] **步骤 2：运行 focused tests**

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/presenter_workflow_test.exs test/symphony_elixir/dashboard_live_test.exs
```

预期：通过。

- [ ] **步骤 3：运行 spec 检查**

```bash
cd elixir
mise exec -- mix specs.check
```

预期：通过。

- [ ] **步骤 4：运行完整 gate**

```bash
cd elixir
mise exec -- make all
```

预期：通过。如果本机仍缺 `mise`，记录明确 blocker，并运行能运行的最强替代命令。

- [ ] **步骤 5：检查最终 diff**

```bash
git status --short
git diff --stat
git diff --check
```

预期：只包含 presenter、dashboard LiveView、workflow LiveView、router、CSS、测试和必要 docs；`git diff --check` 退出码 0。

- [ ] **步骤 6：提交格式化或文档尾项**

若 `mix format` 或 docs 产生额外修改：

```bash
git add elixir docs
git commit -m "chore(dashboard): finalize workflow dashboard"
```

## 自检

- 规格覆盖：
  - root workflow 首页：任务 1、3、5。
  - attention inbox：任务 1、3、5。
  - 详情页：任务 2、4。
  - 降级和兼容：任务 1、2、5。
  - 验证：任务 1 到 6。
- 占位扫描：未发现未定项或“稍后实现”类占位。
- 类型一致性：
  - `root_issue_identifier`、`workflow_phase`、`attention_items`、`runtime_entries`、`nodes`、`edges` 在 presenter、LiveView 和测试中保持一致。
  - `lib/` 下新增 public 函数必须有 `@spec`；Phoenix callback 使用 `@impl true`。
