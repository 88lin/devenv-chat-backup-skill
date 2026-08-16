# devenv-chat-backup — Skill 包

华为云 DevEnv 聊天历史自动备份与恢复方案，封装为可复用的 Skill。

## 这是什么？

华为云 DevEnv 使用 overlay 文件系统，容器重建时 overlay 层数据会被清除，导致聊天历史、记忆数据库等全部丢失。本 skill 提供一套完整的自动备份+恢复方案，使用 GitHub 私有仓库，**完全免费**。

## 快速使用

### 方式一：作为 Skill 安装

```bash
npx skills add https://github.com/88lin/devenv-chat-backup-skill.git --skill devenv-chat-backup -y
```

安装后，AI Agent 会自动在检测到聊天历史丢失问题时触发本 skill。

### 方式二：直接使用脚本

1. 创建 GitHub 私有仓库
2. 修改 `scripts/chat-backup.sh` 顶部的配置变量
3. 执行 `./chat-backup.sh setup`

## 文件结构

```
devenv-chat-backup/
├── SKILL.md                    # Skill 主文档（AI 读取）
├── scripts/
│   ├── chat-backup.sh          # 备份/恢复脚本（参数化模板）
│   ├── github-accel.sh         # GitHub 加速方案（镜像回退）
│   └── keepalive.sh            # tmux 防断开保活 + 心跳检测
├── references/
│   ├── pitfalls.md             # 18 个踩坑经验 + 解决方案
│   ├── architecture.md         # 方案架构和设计决策
│   └── recovery-guide.md       # 容器重建后恢复步骤
└── README.md                   # 本文件
```

## 会话可见性管理

DevEnv UI 有两个隐藏限制，本 skill 已自动处理：

### 1. metadata.source="acp" 过滤

通过 ACP 创建的会话 `metadata` 含 `{"source":"acp",...}`，DevEnv UI 会过滤掉这些会话。
`fix-visibility` 命令自动清除 metadata，使所有会话可见：

```bash
/root/chat-backup.sh fix-visibility  # 手动修复
# backup 和 restore 时也会自动执行
```

### 2. UI 最多显示10个会话

DevEnv UI 硬编码 `LIMIT 10`，超过10个会话时较早/消息较少的不会显示。
`prune` 命令列出候选会话并要求确认后才删除，**默认不自动删除**：

```bash
/root/chat-backup.sh prune  # 手动清理（交互式确认）
# backup/restore 时默认只警告不删除（AUTO_PRUNE=false）
# 如需自动删除：编辑脚本顶部 AUTO_PRUNE=true
# 修改脚本顶部 MAX_SESSIONS=10 可调整限制
```

## 会话索引

每次备份自动生成 `sessions-index.md`，将不可读的会话 ID 映射为可读的中文标题：

```
| 序号 | 日期       | 消息数 | 标题                           | 会话ID      |
|------|------------|--------|--------------------------------|------------|
| 1    | 2026-08-15 | 40     | 帮我看看这个项目的登录模块...   | 01KZYF7R6...|
| 2    | 2026-08-15 | 105    | 帮我部署这个pr，我需要前端...   | 01KZY1TGE...|
```

在 GitHub 仓库中打开此文件即可一眼看出哪个会话是哪个。

## GitHub 加速

当直连 GitHub 慢或打不开时，自动切换到 `tvv.tw` 镜像：

```bash
# 加载加速脚本
source scripts/github-accel.sh

# 克隆（直连失败自动切换镜像）
gclone https://github.com/user/repo.git

# 拉取/推送
gpull origin main
gpush origin main

# 下载 raw 文件
graw https://raw.githubusercontent.com/user/repo/main/file.sh -o local.sh
```

支持所有 GitHub 链接类型：clone、raw、release、gist、API。

## 核心经验

本 skill 凝聚了在实际 DevEnv 环境中踩过的 **18 个关键坑**：

| # | 问题 | 解决方案 |
|---|------|----------|
| 1 | rsync 不可用 | 用 `cp -rf` 替代 |
| 2 | git 命令无超时会卡死 | 所有 git 命令加 `timeout 30s` |
| 3 | 守护进程 CWD 丢失 | 启动时 `cd /root` |
| 4 | crontab 不可用 | `setsid + nohup + while 循环` |
| 5 | curl 被 DNS 限制 | 恢复命令用 `git clone` |
| 6 | .bashrc 在 overlay 层 | 容器重建后需手动恢复一次 |
| 7 | git 等待输入卡死 | `GIT_TERMINAL_PROMPT=0` |
| 8 | 僵尸 git 进程堆积 | timeout 防止 + 清理 index.lock |
| 9 | GitHub 直连慢/打不开 | `tvv.tw` 镜像自动回退 |
| 10 | 每次重连要手动选 allow | `settings.json` 设 `permission: allow` |
| 11 | SQLite WAL 库裸拷即损坏 | 用 `sqlite3 .backup` 快照，恢复前退出聊天并清 `-wal/-shm` |
| 12 | .bashrc 自动 restore 覆盖数据库 → AI 损坏 | .bashrc 只放 daemon，restore 改手动执行 |
| 13 | exec tmux attach 替换 shell → DevEnv 连接断开 | 改为提示信息，不自动 exec |
| 14 | `cp -rf` 不保留时间戳 → 备份文件全显示同一日期 | 改用 `cp -rfp` 保留原始 mtime |
| 15 | 会话文件只有 ID 文件名，无法分辨哪个是哪个 | 自动生成 `sessions-index.md`，提取首条用户消息作为标题 |
| 16 | restore 跳过数据库 → 会话标题丢失，界面只显示 ID | 改用 SQLite ATTACH 安全合并 sessions + messages |
| 17 | sessions.title 有标题但界面仍显示 ID → messages 表为空 | restore 时从 .jsonl 文件补充 messages 表（`import_messages_from_jsonl`） |
| 18 | metadata.source="acp" → 会话在 UI 中不可见 | `fix-visibility` 清除 metadata 为 `{}` |
| 19 | DevEnv UI 最多显示10个会话 | `prune` 自动清理消息少的旧会话 |

详见 [references/pitfalls.md](references/pitfalls.md)

## 适用场景

- ✅ 华为云 DevEnv 环境聊天历史保护
- ✅ 任何 overlay/容器环境的数据持久化
- ✅ 需要免费、可靠的自动备份方案
- ✅ 需要容器重建后一键恢复

## License

MIT
