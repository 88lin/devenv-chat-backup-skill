# devenv-chat-backup-skill

华为云 DevEnv 聊天历史自动备份与恢复 + GLM Proxy 备份 + 容器保活 **统一方案**。

## 解决什么问题？

DevEnv 容器重建时 overlay 层数据被清除，导致聊天历史、数据库、配置全部丢失。
本 skill 通过 GitHub 私有仓库自动备份，支持一键恢复。

## 包含脚本

| 脚本 | 说明 |
|------|------|
| `scripts/chat-backup.sh` | 聊天数据 + GLM Proxy 备份/恢复核心（284行） |
| `scripts/keepalive.sh` | 容器保活 + 进程守护（85行） |
| `scripts/github-accel.sh` | GitHub 加速：镜像回退 + 重试（152行） |
| `scripts/auto-restore.sh` | 🆕 容器重启一键恢复全部服务（132行） |

## 快速部署

```bash
# 1. 创建 GitHub 私有仓库，生成 Personal Access Token

# 2. 克隆并部署
git clone https://YOUR_TOKEN@github.com/YOUR_USER/YOUR_REPO.git /root/chat-backup-new
cp /root/chat-backup-new/scripts/*.sh /root/
chmod +x /root/*.sh

# 3. 修改 chat-backup.sh 顶部的 REPO_URL 为你的仓库地址

# 4. 一键设置
/root/chat-backup.sh setup

# 5. 配置自动恢复（容器重启自动执行）
echo 'bash /root/auto-restore.sh 2>/dev/null' >> /root/.bashrc
```

## 容器重建后恢复

```bash
# 自动恢复（推荐，.bashrc 已配置）
# 或手动执行：
bash /root/auto-restore.sh
```

恢复顺序：聊天数据 → GLM Proxy → 保活守护 → 备份守护

## 详细文档

- [SKILL.md](SKILL.md) — 完整使用说明
- [references/pitfalls.md](references/pitfalls.md) — 踩坑记录
- [references/architecture.md](references/architecture.md) — 架构设计
- [references/recovery-guide.md](references/recovery-guide.md) — 恢复指南

## 安装为 Skill

```bash
npx skills add https://github.com/88lin/devenv-chat-backup-skill --skill devenv-chat-backup -y
```
