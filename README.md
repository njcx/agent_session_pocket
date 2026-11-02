# agent-session-export

一套跨 AI 编程助手（Claude Code / Codex CLI / Pi）的**会话导出 + 自动恢复 + 跨 agent 迁移**工具，由一个 `install.sh` 完成全部安装。

## 功能

- **会话导出**：每个 agent 会话结束后，自动把会话文件导出到当前目录的 `.session/` 下
- **自动 resume**：`claude-s` / `codex-s` / `pi-s` 启动时，若 `.session/` 里有本 agent 的会话，自动带着历史 resume
- **跨 agent 迁移**：本 agent 没有会话时，自动用 [session-migrate](https://github.com/xhluca/session-migrate) 从其他 agent 的最新会话迁移过来
- **去重导出**：源会话内容未变化时跳过导出，不产生重复文件
- **Git 分享**：`.session/` 跟随仓库提交——一次 commit 同时留下代码和产生这些代码的完整对话

## 安装

```bash
bash install.sh
source ~/.zshrc   # 或 ~/.bashrc；新开终端自动生效
```

### 强制依赖

安装脚本会强制检查以下依赖，缺失则中止安装（脚本会打印对应平台的安装命令）：

| 依赖 | 用途 | 安装方式 |
|---|---|---|
| jq | 解析 session id、hook 输入 | macOS: `brew install jq`；Linux: `sudo apt install jq` |
| python3 | settings.json 的 hook 注册 | macOS: `brew install python3`；Linux: `sudo apt install python3` |
| uv | Python 工具管理 | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| session-migrate | 跨 agent 会话迁移 | 由脚本自动执行 `uv tool install session-migrate` |

一条命令装齐基础依赖：

```bash
# macOS
brew install jq python3
# Debian/Ubuntu
sudo apt install jq python3
# Fedora/RHEL
sudo dnf install jq python3
```

## 安装了什么

| 路径 | 内容 |
|---|---|
| `~/.local/bin/agent-session-export` | 主脚本：手动/自动导出会话 |
| `~/.claude/hooks/export-session-to-project.sh` | Claude SessionEnd 钩子 |
| `~/.claude/settings.json` | 注册 SessionEnd hook |
| `~/.bashrc` / `~/.zshrc` | `claude-s` 等三个 shell 函数 |

## 使用

### 启动包装函数

```bash
claude-s          # 有 .session/claude 会话 → 自动 resume；没有 → 新开
codex-s           # 同上，支持从其他 agent 迁移
pi-s              # 同上
```

启动时的完整决策流程（以 `pi-s` 为例）：

```
当前目录无 .session/
  └→ 直接新开（首次使用，退出后自动创建 .session/）

有 .session/，且原生会话目录里已有本 agent 会话
  └→ 直接 resume

有 .session/ 的本 agent 文件，但原生目录里没有（新机器/新 agent）
  └→ smigrate import 导入原生会话目录 → 用新 session id resume

没有本 agent 的会话，但有其他 agent 的会话
  └→ 挑选修改时间最新的一个 → smigrate 迁移导入 → resume
```

### 环境变量

```bash
ASE_FRESH=1 pi-s   # 强制新开：不 resume、不迁移
```

以下参数会跳过自动 resume，原样透传：`-h/--help`、`--resume`、`--continue`、`--session`、`--session-id`

### 手动导出

```bash
session-snap        # 导出当前目录所有 agent 的最新会话到 .session/
```

或直接调主脚本：

```bash
agent-session-export claude                    # 导出 claude
agent-session-export codex "$PWD"              # 导出 codex，指定目录
agent-session-export auto "$PWD"               # 导出全部
```

## `.session/` 目录结构

```
.session/
├── latest-claude.jsonl                       # 各 agent 最新会话（原生格式）
├── latest-codex.jsonl
├── latest-pi.jsonl
└── 20261102-144935-claude-<session-id>.jsonl # 时间戳历史版本
```

三个 agent 均导出**原生会话文件**（与各 agent 自身存储格式一致），可直接被 session-migrate 识别为迁移源。

## Git 分享：代码 + 对话一起提交

`.session/` 是普通目录，直接随仓库提交即可。协作者 clone 后 `claude-s`（或其他 `xxx-s`）会自动 resume 你的会话历史——**上下文跟代码一起走**。

```bash
git add .session/
git commit -m "feat: xxx + session"
git push
```

协作者拿到仓库后：

```bash
bash install.sh && source ~/.zshrc   # 先装好本工具
cd your-project
claude-s        # 自动 resume 仓库里携带的会话，接着你的上下文干活
```

跨 agent 接力也成立：你用 claude 写的代码，协作者可以直接 `codex-s` —— 会话会自动迁移成 codex 格式再 resume。

### 建议

提交前加个 `.gitignore` 控制内容，避免仓库膨胀：

```gitignore
# 只保留各 agent 最新一份，不提交时间戳历史
.session/*-20*
```

或反过来只跟踪 `latest-*`（推荐，历史进本地就够）：

```gitignore
.session/*
!.session/latest-claude.jsonl
!.session/latest-codex.jsonl
!.session/latest-pi.jsonl
```

### 注意

- `.session/` 里的对话是**明文**，包含你与 AI 的全部交互（提示词、代码、命令输出）。公开仓库提交前先确认没有敏感信息（密钥、内部地址等）
- `latest-*.jsonl` 体积小，适合提交

## 跨 agent 迁移矩阵

三个 agent 互迁全部支持，源文件质量（消息保留度）：

| 源 \ 目标 | claude | codex | pi |
|---|---|---|---|
| **claude** | ✅ | ✅ | ✅ |
| **codex** | ✅ | ✅ | ✅ |
| **pi** | ✅ | ✅ | ✅ |

说明：

- 用户/助手消息、工具调用在各条链路均保留
- 各 agent 特有的元数据（title、thinking 等级等）会按 smigrate 规则丢弃，无消息损失
- provider 绑定的 thinking 痕迹不可迁移（所有工具的限制）

## 卸载

```bash
rm -f ~/.local/bin/agent-session-export
rm -f ~/.claude/hooks/export-session-to-project.sh
# settings.json：删除 SessionEnd 中指向 export-session-to-project 的 hook 条目
# ~/.bashrc / ~/.zshrc：删除 "# >>> agent-session-export >>>" 到 "# <<< ... <<<" 的整块
```

## 常见问题

**Q: 新开的终端里函数不生效？**
安装只对新 shell 生效（rc 文件已写入）。当前终端执行 `source ~/.zshrc`。

**Q: 为什么退出 pi 后没有生成 `.session/latest-pi.jsonl`？**
去重逻辑：会话内容与上次导出一致时跳过（输出 `skip: pi session unchanged`）。

**Q: TUI 程序误吞了我的键盘输入？**
旧版本存在 `||` 降级链导致 TUI 异常退出后连环重启的问题，现版本已改为"启动前探测参数、只启动一次"，如仍出现请反馈。

**Q: Ctrl+C 退出后导出被中断？**
wrapper 在 TUI 退出后的导出阶段屏蔽了 SIGINT，正常情况 Ctrl+C 不会影响导出。
