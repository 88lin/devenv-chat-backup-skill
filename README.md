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
│   ├── pitfalls.md             # 8 个踩坑经验 + 解决方案
│   ├── architecture.md         # 方案架构和设计决策
│   └── recovery-guide.md       # 容器重建后恢复步骤
└── README.md                   # 本文件
```

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

本 skill 凝聚了在实际 DevEnv 环境中踩过的 **8 个关键坑**：

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

详见 [references/pitfalls.md](references/pitfalls.md)

## 适用场景

- ✅ 华为云 DevEnv 环境聊天历史保护
- ✅ 任何 overlay/容器环境的数据持久化
- ✅ 需要免费、可靠的自动备份方案
- ✅ 需要容器重建后一键恢复

## License

MIT
