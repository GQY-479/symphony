# Root Workflow 看板改版设计

## 背景

Symphony 的原看板主要围绕运行中的 session、重试队列、阻塞条目和 token 使用量展示状态。随着 issue 驱动动态编排能力加入，单个 Linear issue 不再总是一次直接执行：root issue 可能先进入 planning，派生多个执行节点，再经过 completion packet、review decision、返工、重规划或人工输入收口。

旧看板仍能回答“现在有几个 agent 在跑”，但很难回答“一个 root workflow 整体推进到哪里了”“哪个节点挡住了下游”“哪些任务需要人处理”。新版看板应把操作员的主视角从 session 列表提升到 root workflow。

## 目标

- 首页以 root workflow 为主轴，而不是以单个 session 为主轴。
- 保留快速运维能力：运行中、重试、阻塞、人工输入、rate limit 和 token 使用仍然可见。
- 点进 root workflow 后，能看到轻量链路详情：节点、依赖、阶段、状态、交接摘要、审查结果和阻塞原因。
- 数据整理集中在 presenter/projection 层，LiveView 只负责渲染。
- 对未启用 orchestration 或 registry 不可读的场景提供明确降级。

## 非目标

- 首版不提供在看板中编辑 workflow、移动节点或改变 Linear 状态的能力。
- 首版不引入数据库；继续基于 orchestrator snapshot 和文件型 workflow registry。
- 首版不做复杂交互式图编辑器。详情页只需要清晰展示节点链路。
- 首版不替代现有 JSON API；可以扩展投影，但不破坏现有字段。

## 用户体验

首页采用三栏作战室布局：

- 左栏：筛选与范围选择。
- 中栏：root workflow 平衡卡片列表。
- 右栏：人工动作收件箱和高优先级阻塞项。

中栏默认每个 root workflow 一张紧凑卡片。卡片应展示：

- root issue identifier、标题和外部 tracker 链接。
- workflow 整体状态，例如 `planning`、`running`、`reviewing`、`blocked`、`retrying`、`replanning`、`completed`。
- 阶段进度摘要，例如 planning、execution、review、rework、closure 的当前落点。
- 当前活跃节点数量、阻塞节点数量、重试节点数量。
- 最近 agent 事件和发生时间。
- token/runtime 摘要。
- 下一步需要关注的动作，例如“等待 review decision”“需要人工输入”“重试将在 42s 后开始”。

右栏显示需要操作员关注的条目，优先级从高到低：

- planning 输出 `needs_human_input`。
- review decision 为 `needs_human` 或 `fail`。
- workflow_blocked_reason 非空的 blocked 条目。
- 重试次数较高或即将再次重试的条目。
- registry 不可读或 snapshot 不可用等系统异常。

点击 root workflow 卡片进入轻量详情视图。详情页展示：

- root issue 基本信息和整体状态。
- 节点列表或轻量依赖图，标明每个节点的 issue、task type、workflow phase、节点状态和 agent。
- 依赖关系和被阻塞原因。
- completion packet 摘要、证据数量和下游 handoff 摘要。
- review decision、review summary、rework/replan 历史。
- 相关 session、workspace、最近事件和 JSON 详情链接。

## 数据投影

现有 `Presenter.state_payload/2` 继续返回兼容的 `running`、`retrying`、`blocked`、`codex_totals` 和 `rate_limits`。新增 workflow 视角投影：

```elixir
%{
  workflows: [
    %{
      root_issue_identifier: String.t(),
      root_issue_id: String.t() | nil,
      title: String.t() | nil,
      issue_url: String.t() | nil,
      status: String.t(),
      phase_summary: map(),
      counts: %{
        running: non_neg_integer(),
        retrying: non_neg_integer(),
        blocked: non_neg_integer(),
        completed: non_neg_integer() | nil,
        total_nodes: non_neg_integer() | nil
      },
      active_entries: [map()],
      attention_items: [map()],
      recent_event: map() | nil,
      tokens: map(),
      runtime_seconds: non_neg_integer(),
      registry_available?: boolean()
    }
  ],
  attention_items: [map()]
}
```

`workflow_root_issue_id` 或 root identifier 是聚合主键。对于没有 workflow root 信息的旧式 session，presenter 应生成一个兼容的 pseudo workflow 卡片，状态标为 `direct_execution`，保证未启用 orchestration 时首页仍有内容。

详情页需要 registry 摘要。可以先在 presenter 中读取 `SymphonyElixir.Workflow.Registry` 文件，返回只含看板需要字段的投影，而不是把 registry 原始 JSON 直接交给 LiveView。

## 路由与组件

建议新增或调整以下 UI 单元：

- `DashboardLive`：首页三栏布局，消费 workflow 投影。
- `WorkflowLive` 或同等详情 LiveView：展示单个 root workflow。
- 可复用组件：
  - workflow 卡片
  - attention item
  - phase badge
  - node status row
  - token/runtime summary
  - event summary

路由建议：

- `/`：新版首页。
- `/workflows/:root_identifier`：root workflow 详情。
- `/api/v1`：继续返回全局观测 JSON，可包含新增 `workflows` 字段。
- `/api/v1/:issue_identifier`：保持现有 issue 详情语义。

## 降级与错误处理

- orchestrator snapshot timeout：显示全页错误状态，并保留生成时间。
- registry 不存在：workflow 卡片仍从 snapshot 聚合，详情页显示“registry 暂不可用”，并列出可见 session。
- orchestration 未启用：显示 direct execution 卡片，不显示节点图谱入口或显示为空态说明。
- root workflow 没有活跃 session：如果 registry 存在，仍可显示 completed、blocked、replanning 等静态状态；如果 registry 不存在，则不出现在首页。
- 无任何工作：显示安静空态，包括项目链接、下次刷新时间和 rate limit 摘要。

## 测试计划

- Presenter 聚合测试：
  - 多个 running/retry/blocked 条目按同一 root 聚合。
  - 没有 workflow root 的旧式条目降级为 direct execution workflow。
  - attention items 按人工输入、review fail、blocked、retry 排序。
  - registry 存在和缺失时输出稳定。
- LiveView 渲染测试：
  - 首页显示 root workflow 卡片、右侧 attention inbox 和空态。
  - 详情页显示节点、依赖、packet 摘要和 review 摘要。
  - snapshot timeout 显示错误状态。
- 现有 status dashboard snapshot 测试继续通过；如文本输出也加入 workflow 字段，只更新相关快照。

## 实施顺序

1. 在 presenter 层新增 workflow 聚合投影，保持现有 API 字段兼容。
2. 为 registry 摘要读取增加小型投影函数和测试。
3. 重写 dashboard 首页 LiveView 为三栏 root workflow 布局。
4. 新增 root workflow 详情路由和 LiveView。
5. 更新 CSS，采用更适合运维扫描的紧凑布局。
6. 补齐测试和快照。

## 已确认决策

- 首页采用 C2：root workflow 优先。
- 默认密度采用平衡卡片列表。
- 首页右侧保留人工动作收件箱。
- 首版包含轻量 root workflow 详情视图。
