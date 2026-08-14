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
│  │  (自动恢复)    │    │  每120s backup    │   │
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

# 一键设置（首次备份 + 启动守护进程 + 配置 .bashrc）
/root/chat-backup.sh setup
```

> ⚠️ **请将 `YOUR_TOKEN`、`YOUR_USER`、`YOUR_REPO` 替换为你自己的值！**
> - `YOUR_TOKEN`：你的 GitHub Personal Access Token（需 repo 权限）
> - `YOUR_USER`：你的 GitHub 用户名
> - `YOUR_REPO`：你创建的私有仓库名

### 3. 容器重建后恢复

容器重建后，打开你自己的 GitHub 仓库页面，复制 README 中的恢复命令执行即可。

## 核心功能

### 聊天备份

| 命令 | 说明 |
|------|------|
| `chat-backup.sh setup` | 首次设置：备份 + 启动守护进程 + 配置 .bashrc |
| `chat-backup.sh backup` | 立即备份当前数据到 Git |
| `chat-backup.sh restore` | 从 Git 恢复最新数据 |
| `chat-backup.sh daemon` | 启动后台守护进程（每120秒备份） |
| `chat-backup.sh status` | 查看备份状态 |

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
| `sessions/*.jsonl` | 聊天会话记录 |
| `memory.db` | 语义记忆数据库 |
| `audit.db` | 审计日志数据库 |
| `settings.json` | 用户设置 |
| `SOUL.md` | Agent 人格配置 |
| `user_info.json` | 用户信息 |

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
- **重连**：自动进入 tmux，显示断开时长提醒
- **手动进入**：`tmux attach -t devenv`
- **临时退出**：`Ctrl+B` 然后按 `D`（会话保持运行）

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

## References

| 文档 | 说明 |
|------|------|
| [pitfalls.md](references/pitfalls.md) | 所有踩过的坑和解决方案 |
| [architecture.md](references/architecture.md) | 方案架构和设计决策详解 |
| [recovery-guide.md](references/recovery-guide.md) | 容器重建后恢复步骤 |
