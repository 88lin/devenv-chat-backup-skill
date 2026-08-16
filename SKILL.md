---
name: devenv-chat-backup
description: |
  华为云 DevEnv 聊天历史自动备份与恢复方案。解决 DevEnv 容器重建导致 overlay 层数据丢失、
  聊天历史消失的问题。使用 GitHub 私有仓库定期备份，完全免费。
  当用户遇到以下情况时触发本 skill：
  (1) DevEnv 断连重连后历史记录丢失
  (2) 需要自动备份聊天会话数据
  (3) 容器重建后需要恢复聊天历史
  (4) 想搭建可靠的聊天历史备份方案
  触发词：聊天历史丢失、历史记录消失、断连重连、容器重建、备份聊天、恢复聊天、
  DevEnv 备份、overlay 丢失、chat backup、history lost、session recovery
---

# DevEnv Chat Backup — 聊天历史自动备份与恢复

解决华为云 DevEnv 容器重建导致聊天历史丢失的问题。使用 GitHub 私有仓库自动备份，完全免费。

## 问题根因

华为云 DevEnv 使用 overlay 文件系统。容器重建时 overlay 层数据被清除，导致：
- 聊天会话文件（sessions/）全部消失
- memory.db、audit.db 等数据库丢失
- .bashrc 等配置文件被重置

**这不是 bug，是 overlay FS 的设计特性。** 容器重建后只有镜像层的数据保留。

## 方案架构

```
┌─────────────────────────────────────────────┐
│              DevEnv 容器                      │
│                                               │
│  ┌──────────────┐    ┌──────────────────┐   │
│  │  聊天数据      │───→│  chat-backup.sh   │   │
│  │  sessions/    │    │  (备份脚本)        │   │
│  │  memory.db    │    └────────┬─────────┘   │
│  │  settings.json│             │              │
│  └──────────────┘             │              │
│                               ▼              │
│  ┌──────────────┐    ┌──────────────────┐   │
│  │  .bashrc      │───→│  守护进程          │   │
│  │  (自动备份)    │    │  每120s backup    │   │
│  └──────────────┘    └────────┬─────────┘   │
│                                │              │
└────────────────────────────────┼─────────────┘
                                 │
                                 ▼
                    ┌────────────────────────┐
                    │  GitHub 私有仓库         │
                    │  (免费、可靠、可追溯)    │
                    └────────────────────────┘
```

### 为什么选 GitHub 私有仓库？

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| GitHub 私有仓库 | 免费、可靠、git 版本控制 | 需要配置 token | ✅ 采用 |
| 华为云 OBS | 对象存储、可靠 | 收费、需额外配置 | ❌ 否决 |
| 本地备份 | 简单 | 容器重建一起丢 | ❌ 否决 |

## 快速开始

### 1. 创建 GitHub 私有仓库

在 GitHub 创建一个私有仓库（如 `devenv-chat-backup`），生成 Personal Access Token（需要 repo 权限）。

### 2. 部署备份脚本

```bash
# 配置 Git 凭证
git config --global credential.helper store
echo "https://YOUR_TOKEN@github.com" > ~/.git-credentials

# 克隆仓库
git clone https://YOUR_TOKEN@github.com/YOUR_USER/YOUR_REPO.git /root/chat-backup-new

# 复制备份脚本
cp /root/chat-backup-new/scripts/chat-backup.sh /root/chat-backup.sh
chmod +x /root/chat-backup.sh

# 修改脚本顶部的 REPO_URL 为你自己的仓库地址
# （编辑 /root/chat-backup.sh 第 19 行的 REPO_URL）

# 一键设置（首次备份 + 启动守护进程 + 配置 .bashrc + 开启免确认）
/root/chat-backup.sh setup
```

> ⚠️ **请将 `YOUR_TOKEN`、`YOUR_USER`、`YOUR_REPO` 替换为你自己的值！**
> - `YOUR_TOKEN`：你的 GitHub Personal Access Token（需 repo 权限）
> - `YOUR_USER`：你的 GitHub 用户名
> - `YOUR_REPO`：你创建的私有仓库名

### 3. 开启自动批准（免确认）

`setup` 已自动开启。如需单独操作：

```bash
# 开启免确认（所有工具调用自动批准，不用每次手动选 allow）
/root/chat-backup.sh auto-approve
```

> `.bashrc` 只启动备份守护进程，不自动 restore。容器重建后需手动执行 `/root/chat-backup.sh restore` 恢复数据（含 settings.json）。

### 3. 容器重建后恢复

容器重建后，打开你自己的 GitHub 仓库页面，复制 README 中的恢复命令执行即可。

> ⚠️ **重要**：`setup` 不会自动 `restore`。容器重建后请**手动执行一次** `/root/chat-backup.sh restore` 恢复历史数据。
> restore 现在使用**安全合并**模式：AI 运行时用 SQLite ATTACH + INSERT OR REPLACE 合并数据库，不会覆盖活跃数据。

## 核心功能

### 聊天备份

| 命令 | 说明 |
|------|------|
| `chat-backup.sh setup` | 首次设置：自动批准 + 备份 + 启动守护进程 + 配置 .bashrc（仅 daemon，不自动 restore） |
| `chat-backup.sh backup` | 立即备份当前数据到 Git（自动修复可见性 + 清理多余会话） |
| `chat-backup.sh restore` | 从 Git 恢复最新数据（安全合并 + 补充 messages + 修复可见性 + 清理多余会话） |
| `chat-backup.sh daemon` | 启动后台守护进程（每120秒备份） |
| `chat-backup.sh status` | 查看备份状态 |
| `chat-backup.sh auto-approve` | 开启自动批准（免确认，修改 settings.json） |
| `chat-backup.sh fix-visibility` | 🆕 修复会话可见性（清除 metadata.source="acp"） |
| `chat-backup.sh prune` | 🆕 清理多余会话（交互式确认，保留消息最多的最近 N 个，默认 N=10） |
| `chat-backup.sh delete` | 交互式删除会话（支持关键词/日期/空会话筛选） |

### 防断开保活

| 命令 | 说明 |
|------|------|
| `keepalive.sh setup` | 防断开保活设置（tmux + 心跳 + .bashrc） |
| `keepalive.sh status` | 查看保活状态 |
| `keepalive.sh log` | 查看断开/恢复记录 |
| `keepalive.sh attach` | 进入 tmux 会话 |

### GitHub 加速（镜像回退）

| 命令 | 说明 |
|------|------|
| `gclone <url> [dir]` | git clone 带镜像回退 |
| `gpull [remote] [branch]` | git pull 带镜像回退 |
| `gfetch [remote] [branch]` | git fetch 带镜像回退 |
| `gpush [remote] [branch]` | git push 带重试（镜像不支持 push） |
| `graw <url> [-o file]` | 下载 raw 文件带镜像回退 |
| `ggit <subcmd> ...` | 通用 git 加速器（自动选择上述函数） |

## 备份内容

| 文件 | 说明 |
|------|------|
| `sessions/*.jsonl` | 聊天会话记录（保留原始时间戳） |
| `sessions-index.md` | 🆕 可读会话索引：ID → 中文标题 → 日期 → 消息数 |
| `sessions-index.json` | 🆕 程序可读的会话索引（JSON 格式） |
| `memory.db` | 语义记忆数据库（sessions + messages 表） |
| `audit.db` | 审计日志数据库 |
| `settings.json` | 用户设置 |
| `SOUL.md` | Agent 人格配置 |
| `user_info.json` | 用户信息 |

> 💡 **会话索引**：每次备份自动生成 `sessions-index.md`，提取每个会话的首条用户消息作为标题。
> 在 GitHub 仓库中打开此文件即可一眼看出哪个会话是哪个，不用对着 ID 猜。
>
> ⚠️ **messages 表是关键**：DevEnv 界面从 `messages` 表（不是 `sessions.title`）读取会话显示名。
> restore 时会自动从 `.jsonl` 文件补充 `messages` 表（`import_messages_from_jsonl`），
> 确保界面显示中文标题而非 session ID。

## 会话可见性管理

### 问题1：metadata.source="acp" 导致会话不可见

**现象**：通过 ACP（Agent Communication Protocol）创建的会话，其 `metadata` 字段包含 `{"source":"acp",...}`。
DevEnv UI 会过滤掉这些会话，只显示 `metadata={}` 的会话。导致备份了14个会话但UI只显示10个。

**根因**：DevEnv UI 的会话列表查询隐式过滤了 `metadata` 含 `source` 字段的记录。

**解决方案**：`fix_session_visibility()` 函数自动清除 `metadata` 中的 `source` 字段：
```bash
# 手动执行
/root/chat-backup.sh fix-visibility

# 或在 backup/restore 时自动执行
```

### 问题2：DevEnv UI 最多显示10个会话

**现象**：即使所有会话的 metadata 都正确，DevEnv UI 也最多只显示10个会话。
超过10个时，较早或消息较少的会话不会出现在列表中。

**根因**：DevEnv UI 的会话列表有硬编码的 `LIMIT 10`，这是平台限制，无法通过配置修改。

**解决方案**：`prune_sessions()` 函数在会话数超过 `MAX_SESSIONS`（默认10）时，提示用户清理：
```bash
# 手动执行（会列出候选会话并要求确认后才删除）
/root/chat-backup.sh prune

# backup/restore 时默认只警告不自动删除（AUTO_PRUNE=false）
# 如需自动删除，编辑脚本顶部设置 AUTO_PRUNE=true
```

> 💡 **安全策略**：默认 `AUTO_PRUNE=false`，backup/restore 时只列出建议清理的会话但**不自动删除**。
> 手动执行 `prune` 时会显示候选列表并要求 `y/N` 确认后才删除。
> prune 按 `message_count` 升序 + `start_timestamp` 升序排序，优先删除消息少且时间早的会话。
> 这样保留的是对话最丰富、最近的会话。

## 防断开保活（tmux 方案）

> 断连后正在运行的命令不会中断，重连自动恢复

```bash
# 安装 tmux（EulerOS）
dnf install -y tmux

# 一键设置防断开
./scripts/keepalive.sh setup
```

设置后：
- **断开**：tmux 会话保持运行，命令不中断
- **重连**：显示提示信息（不自动 exec tmux attach，避免替换 shell 导致 DevEnv 连接断开）
- **手动进入**：`tmux attach -t devenv`
- **临时退出**：`Ctrl+B` 然后按 `D`（会话保持运行）

> ⚠️ **为什么不自动进入 tmux？** 原方案用 `exec tmux attach` 替换 shell 进程，但 DevEnv 的终端管理通过 WebSocket 与 bash 通信，shell 被 exec 掉后 DevEnv 认为终端已死 → 连接断开。改为仅提示。

## GitHub 加速（镜像回退）

> 当直连 GitHub 慢或打不开时，自动切换到 `tvv.tw` 镜像

```bash
# 加载加速脚本（已配置在 .bashrc 中自动加载）
source /root/github-accel.sh

# 克隆仓库（直连失败自动切换镜像）
gclone https://github.com/user/repo.git /path/to/clone

# 拉取/推送（在仓库目录内）
gpull origin main
gpush origin main

# 下载 raw 文件（直连失败自动切换镜像）
graw https://raw.githubusercontent.com/user/repo/main/file.sh -o local.sh

# 通用 git 加速器
ggit clone https://github.com/user/repo.git
ggit pull origin main
ggit push origin main
```

**工作原理**：
- `clone/fetch/pull`（读操作）：先直连 15s 超时，失败后自动用 `https://tvv.tw/` 镜像重试
- `push`（写操作）：镜像不支持 push，自动重试 3 次（每次 60s 超时）
- 镜像克隆后自动修复 remote URL，确保后续 push 走直连不走镜像

## 关键经验与避坑指南

> ⚠️ 以下经验全部来自实际踩坑，详见 [references/pitfalls.md](references/pitfalls.md)

1. **rsync 不可用** → 用 `cp -rf` 替代（DevEnv 精简环境无 rsync）
2. **git 命令无超时会卡死** → 所有 git 命令加 `timeout 30s`
3. **守护进程 CWD 会丢失** → 启动时 `cd /root`
4. **crontab 不可用** → 用 `setsid + nohup + while 循环` 替代
5. **curl 被 DNS 限制** → 恢复命令必须用 `git clone`，不能用 curl
6. **.bashrc 在 overlay 层** → 容器重建后 .bashrc 丢失，需手动执行一次恢复命令
7. **GIT_TERMINAL_PROMPT=0** → 防止 git 等待输入导致守护进程卡死
8. **僵尸 git 进程堆积** → timeout 防止 + 手动清理 index.lock
9. **.bashrc 自动 restore 损坏数据** → .bashrc 只放 daemon，restore 改手动（坑 11）
10. **restore 跳过数据库导致标题丢失** → 改用 SQLite ATTACH 安全合并，不再跳过（坑 15）
11. **sessions.title 有标题但界面仍显示 ID** → messages 表为空，从 .jsonl 补充（坑 16）
12. **exec tmux attach 断开连接** → 改为提示，不替换 shell 进程（坑 12）
13. **metadata.source="acp" 导致会话不可见** → 清除 metadata 为 `{}`（坑 17）
14. **DevEnv UI 最多显示10个会话** → 自动 prune 消息少的旧会话（坑 18）

## References

| 文档 | 说明 |
|------|------|
| [pitfalls.md](references/pitfalls.md) | 所有踩过的坑和解决方案 |
| [architecture.md](references/architecture.md) | 方案架构和设计决策详解 |
| [recovery-guide.md](references/recovery-guide.md) | 容器重建后恢复步骤 |
