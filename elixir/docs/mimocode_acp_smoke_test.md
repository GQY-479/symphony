# MiMo-Code ACP Smoke Test

## 调研结论

- ACP 官方流程是 `initialize` -> `session/new` -> `session/prompt`，运行中通过 `session/update` 推送事件，取消通过 `session/cancel`。
- ACP permission 请求由 agent 调用 client 的 `session/request_permission`。
- MiMo-Code 源码中的 `acp` 命令使用 `@agentclientprotocol/sdk` 的 `AgentSideConnection` 和 `ndJsonStream`。
- MiMo-Code 源码中的 `acp` 命令支持通过 `--cwd` 设置工作目录。

## 本机命令探测

执行命令：

```powershell
wsl.exe -e bash -lc 'set -o pipefail; echo WSL; command -v mimo || true; command -v mimocode || true; command -v mimo-code || true; if command -v mimo >/dev/null 2>&1; then mimo acp --help 2>&1 | head -80; fi'
```

输出：

```text
WSL
```

执行命令：

```powershell
$ErrorActionPreference='SilentlyContinue'; 'Windows'; Get-Command mimo,mimocode,mimo-code | Select-Object Name,Source,CommandType | Format-Table -AutoSize
```

输出：

```text
Windows
```

结论：当前 Windows 和 WSL PATH 中都未发现 `mimo`、`mimocode` 或 `mimo-code` 命令。因此真实 `mimo acp` smoke test 暂时不能执行。

## 方案门禁

当前探测结果不推翻 ACP stdio 方案。原因是：

- MiMo-Code 源码已经暴露 ACP stdio 命令。
- Symphony 侧可以先用 fake ACP server 锁定协议适配和 orchestration 行为。
- 真实 MiMo-Code 验收仍保持未通过，直到本机或 worker 环境安装可执行的 `mimo acp`。

如果后续安装后的 `mimo acp` 不支持 ACP v1 的 `initialize`、`session/new`、`session/prompt`，或不能以非交互方式启动，需要暂停实现并回到设计文档修订。

## 后续 smoke 命令

安装 MiMo-Code 后，执行：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mimo acp --help'
```

再执行最小启动探测：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && timeout 5s mimo acp --cwd "$PWD" < /dev/null || true'
```
