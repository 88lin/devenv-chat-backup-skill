# devenv-chat-backup-skill

华为云 DevEnv 聊天历史自动备份与恢复 + GLM Proxy 备份 + 容器保活 **统一方案**。

## ⚠️ 重要：容器销毁重建后不能全自动

DevEnv 容器**销毁重建**时，overlay 层数据全部清除，包括：
- `/root/*.sh`（所有脚本）
- `/root/.bashrc`（自动恢复配置）
- `/root/.git-credentials`（Git 凭证）

**所以销毁重建后，auto-restore.sh 本身也没了，无法自动执行。**

你需要手动跑 **3 行命令**恢复一切（见下方）。

> **容器重启**（非销毁重建）则全自动恢复，无需任何手动操作。

---

## 两种场景对比

| 场景 | overlay 层 | 脚本/配置 | 是否自动恢复 | 手动操作 |
|------|-----------|----------|------------|---------|
| 容器重启 | 保留 | 都在 | ✅ 全自动 | 无 |
| 容器销毁重建 | 清除 | 全没了 | ❌ 不可能 | 3 行命令 |

---

## 容器销毁重建后的恢复步骤

打开你的 GitHub 备份仓库（如 `ai-shell-backup`），执行以下 3 行命令：

```bash
# 第1行：克隆备份仓库（使用镜像加速，把 YOUR_TOKEN 换成你的 GitHub Token）
git clone https://YOUR_USER:YOUR_TOKEN@ghfast.top/https://github.com/YOUR_USER/ai-shell-backup.git /tmp/recover

# 第2行：复制脚本和配置到 /root/
cp /tmp/recover/scripts/*.sh /root/ && chmod +x /root/*.sh
cp -rf /tmp/recover/scripts/glm-proxy /root/glm-proxy 2>/dev/null
cp -f /tmp/recover/tmp-data/*.txt /tmp/ 2>/dev/null

# 第3行：一键恢复全部服务
bash /root/auto-restore.sh
```

> **镜像不可用？** 去掉 `https://ghfast.top/` 前缀直接克隆即可。

auto-restore.sh 会依次恢复：
1. ✅ 聊天历史（sessions、memory.db、settings.json、SOUL.md）
2. ✅ GLM Proxy 服务（脚本 + 密钥 + 启动）
3. ✅ Cloudflare Tunnel（基于 token 自动连接）
4. ✅ 保活守护进程（每 60 秒检查）
5. ✅ 备份守护进程（每 120 秒自动备份）
6. ✅ .bashrc 自动恢复配置（下次重启就全自动了）

---

## 首次部署（新环境）

### 1. 创建 GitHub 私有仓库

在 GitHub 创建私有仓库（如 `ai-shell-backup`），生成 Personal Access Token（需 repo 权限）。

### 2. 部署脚本

```bash
# 配置 Git 凭证
git config --global credential.helper store
echo "https://YOUR_TOKEN@github.com" > ~/.git-credentials

# 克隆本 skill 仓库（使用镜像加速）
git clone https://ghfast.top/https://github.com/88lin/devenv-chat-backup-skill.git /tmp/skill

# 复制脚本到 /root/
cp /tmp/skill/scripts/*.sh /root/
chmod +x /root/*.sh

# 修改 chat-backup.sh 第 19 行的 REPO_URL 为你的备份仓库地址
# 例如: REPO_URL="https://github.com/YOUR_USER/ai-shell-backup.git"
```

### 3. 启动备份

```bash
# 一键设置（首次备份 + 启动守护进程 + 配置 .bashrc）
/root/chat-backup.sh setup
```

设置完成后：
- 每 120 秒自动备份聊天数据到 GitHub
- 每 60 秒保活检查
- 容器重启时自动恢复（.bashrc 已配置）

---

## 包含脚本

| 脚本 | 行数 | 说明 |
|------|------|------|
| `scripts/chat-backup.sh` | 290 | 聊天数据 + GLM Proxy 备份/恢复核心 |
| `scripts/keepalive.sh` | 92 | 容器保活 + 进程守护 |
| `scripts/github-accel.sh` | 153 | GitHub 加速：镜像回退 + 重试 |
| `scripts/auto-restore.sh` | 140 | 容器重启一键恢复全部服务 |

## 备份内容

| 内容 | 说明 |
|------|------|
| `sessions/*.jsonl` | 聊天会话记录 |
| `memory.db` | 语义记忆数据库 |
| `settings.json` | 用户设置 |
| `SOUL.md` | Agent 人格配置 |
| `scripts/glm-proxy/` | GLM Proxy 服务脚本 |
| `tmp-data/*.txt` | GLM Proxy 密钥/Cloudflare Tunnel Token |

## 常用命令

```bash
# 立即备份
/root/chat-backup.sh backup

# 查看备份状态
/root/chat-backup.sh status

# 手动恢复
/root/chat-backup.sh restore

# 一键恢复全部（销毁重建后用这个）
bash /root/auto-restore.sh

# 查看保活状态
/root/keepalive.sh status
```

## 详细文档

- [SKILL.md](SKILL.md) — 完整使用说明
- [references/pitfalls.md](references/pitfalls.md) — 踩坑记录
- [references/architecture.md](references/architecture.md) — 架构设计
- [references/recovery-guide.md](references/recovery-guide.md) — 恢复指南

## 安装为 Skill

```bash
npx skills add https://github.com/88lin/devenv-chat-backup-skill --skill devenv-chat-backup -y
```
