# Codex Desktop `setup refresh had errors` 事实情况陈述

## 基本信息

- 日期：2026-08-11
- 操作系统：Windows
- 工作区：`E:\Vivado_prj\ZCU111_v11_LFM_RANGE`
- npm Codex CLI：`codex-cli 0.147.0`
- npm 软件包：`@openai/codex@0.147.0`
- npm registry 当时返回的最新版本：`0.147.0`
- 相关 PR：<https://github.com/openai/codex/pull/10648>

## 问题概述

Codex Desktop 当前任务无法通过 unified exec 创建工作区进程。PowerShell、CMD、Git 查询和备用 Node 文件读取均在实际用户命令启动前失败。

统一错误为：

```text
Failed to create unified exec process:
helper_unknown_error: setup refresh had errors
```

即使只执行文本输出或获取当前目录，也出现相同错误：

```powershell
Write-Output 'exec-ok'
Get-Location
```

## 排查过程

### 1. 工作区命令测试

先后尝试了 PowerShell 文本输出、获取当前目录、`git status`、`rg` 文件查询以及 CMD 目录查询。所有命令均未真正启动，并返回：

```text
helper_unknown_error: setup refresh had errors
```

### 2. 备用 Node REPL 测试

备用 Node REPL 同样无法启动，诊断信息为：

```text
windows sandbox failed:
helper_unknown_error: setup refresh had errors
```

这说明当时的问题不局限于 PowerShell。

### 3. 非沙箱执行申请

尝试申请非沙箱只读执行时，审批服务返回：

```text
403 Forbidden
model not allowed
```

这是另一条执行路径上的独立错误。现有证据不能证明它是 setup refresh 失败的根因，但它阻止了通过非沙箱执行绕过故障。

### 4. 手动 Windows sandbox 测试

最初执行：

```powershell
codex sandbox windows cmd /c echo test
```

返回：

```text
windows sandbox failed: runner failed during SpawnChild:
CreateProcessAsUserW failed: 2 (系统找不到指定的文件。)
cwd=C:\Windows\system32
cmd=windows cmd /c echo test
```

日志显示 `windows` 被作为待启动的可执行文件，因此 Windows 返回错误 2。该结果属于命令参数格式问题，不能证明 Windows sandbox 本身损坏。

改用当前 CLI 支持的格式：

```powershell
codex sandbox -- cmd.exe /d /c echo test
```

实际输出：

```text
test
```

这证明 npm CLI 的基础 Windows sandbox 能够创建进程并启动 `cmd.exe`。

### 5. Codex CLI 安装检查

`Get-Command codex -All` 返回三个入口：

```text
C:\Users\HUAWEI\AppData\Roaming\npm\codex.ps1
C:\Users\HUAWEI\AppData\Roaming\npm\codex.cmd
C:\Users\HUAWEI\AppData\Roaming\npm\codex
```

三个入口均位于同一 npm 全局目录，分别供不同 shell 使用，不能据此认定存在三个不同版本。

版本查询结果：

```text
@openai/codex@0.147.0
codex-cli 0.147.0
npm registry latest: 0.147.0
```

因此，npm CLI 安装完整，并且是 npm registry 当时提供的最新版本。

### 6. CLI sandbox 成功后重新测试 Desktop

在手动 CLI sandbox 成功输出 `test` 后，再次测试 Codex Desktop unified exec，错误仍然不变：

```text
helper_unknown_error: setup refresh had errors
```

由此确认：基础 CLI sandbox 成功并不会恢复当时 Desktop 任务的 setup refresh 执行链。

## 已确认事实

1. npm CLI 0.147.0 的基础 Windows sandbox 可以启动 `cmd.exe`。
2. 故障发生时，Codex Desktop unified exec 在实际用户命令启动前失败。
3. 当时的失败点位于 setup/environment refresh 阶段。
4. PowerShell、CMD 和 Node 读取路径均受到影响。
5. 故障与待执行命令的具体内容无关。
6. 没有证据表明 Vivado 工程或 `lfm_radar_core` RTL 导致该故障。
7. CLI sandbox 成功后，Desktop unified exec 当时仍持续失败。

## 尚未确认的事项

1. setup refresh 内部最先失败的具体操作和原始错误。
2. 故障发生时 Codex Desktop 应用的准确版本。
3. Desktop 内置 runner/helper 与 PATH 中 npm CLI 的版本关系。
4. PR #10648 是否已包含在当时的 Desktop 版本或 CLI 0.147.0 中。
5. PR #10648 是否直接覆盖本次故障的触发路径。

## 信息获取限制

排查期间，网页检索接口读取 PR #10648 时返回 404，未能取得 PR 正文、diff、合并时间或 merge commit。因此，不能声称已根据 PR 源码确认修复范围或首个包含修复的版本。

## 故障边界

```text
Codex Desktop unified exec
        |
        v
setup/environment refresh  <-- 当时的失败点
        |
        v
创建 PowerShell/CMD 进程   <-- 未执行到
        |
        v
读取或修改 Vivado 工程     <-- 未执行到
```

手动 npm CLI 测试走的是另一条路径：

```text
codex sandbox -- cmd.exe ...
        |
        v
Windows sandbox 创建进程
        |
        v
成功输出 test
```

## 对工程任务的影响

故障排查期间：

- 未读取 `lfm_radar_core` 当前内容；
- 未执行相关器六级流水修改；
- 未运行 RTL 仿真；
- 未运行 Vivado 综合或时序分析；
- 未修改工程 RTL 文件。

原计划任务为：将 `lfm_radar_core` 相关器拆分为 READ、MULT、ACCUM、DIFF、MAG、UPDATE 六级流水，以解决 `reference_mem` 到 `max_score` CE 的时序错误。

## 后续状态

本报告创建时，本地命令执行已经能够启动。该事实表明先前的 `setup refresh had errors` 状态不再阻止当前会话创建 PowerShell 进程，但不改变上述故障发生期间的记录。

## 结论

故障发生期间，npm CLI 的基础 Windows sandbox 可以正常创建进程，而阻塞点位于 Codex Desktop unified exec 的 setup/environment refresh 链路。由于当时未取得 refresh 内部的第一条原始错误、Desktop 版本及 PR #10648 的合并信息，无法进一步确认具体缺陷位置或修复版本。
