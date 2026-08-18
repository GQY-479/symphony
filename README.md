# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Issue Graph 的 Git 交付边界

在 Issue Graph 模式中，`implementation`、`integration` 和 `review` 只表示当前 issue 的任务责任，
不对应长期驻留或具有独立身份的 agent 实体。统一的 coding agent 按 node 上下文执行不同责任。

可写 issue 的 agent 负责判断需要提交的内容、清理工作区、创建完整提交，以及在私有分支解决
candidate 或 target 冲突；agent 不直接更新共享 candidate 或 target。Workflow Controller 校验 Git
事实后，以 compare-and-swap 受保护地推进共享引用并保存 checkpoint。最终审查绑定 Controller
生成的 target/candidate SHA；任一引用漂移都会使审查失效。只有审查通过的 candidate 已发布到远程
target 且 publication checkpoint 已持久化后，root issue 才能进入 Done。

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

Symphony can watch more than one Linear project from a single workflow. Configure
`tracker.projects` with one entry per Linear project and give each entry the repository address or
addresses that should seed issue workspaces. See [elixir/README.md](elixir/README.md#configuration)
for a complete example with two Linear project-to-repository mappings.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
