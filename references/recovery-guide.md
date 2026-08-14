# 容器重建后恢复指南

## 场景

DevEnv 容器被重建（手动重建、系统维护、自动扩缩容等），所有 overlay 层数据丢失。
聊天历史、记忆数据库、备份脚本、.bashrc 配置全部消失。

## 恢复步骤

### 第一步：获取恢复命令

打开你自己的 GitHub 仓库网页（如 `https://github.com/YOUR_USER/YOUR_REPO`）

查看 README.md 中的「容器重建后一键恢复」部分，复制恢复命令。

> ⚠️ 恢复命令中包含 GitHub Token，请确保只在自己的环境中执行。

### 第二步：执行恢复命令

将复制的命令中的 `YOUR_TOKEN` 替换为你的 GitHub Personal Access Token，然后执行：

```bash
# 1. 配置 Git 凭证
git config --global credential.helper store
echo "https://YOUR_TOKEN@github.com" > ~/.git-credentials

# 2. 克隆备份仓库
git clone https://YOUR_TOKEN@github.com/YOUR_USER/YOUR_REPO.git /root/chat-backup-new

# 3. 复制备份脚本
cp /root/chat-backup-new/scripts/chat-backup.sh /root/chat-backup.sh
chmod +x /root/chat-backup.sh

# 4. 修改脚本顶部配置为你自己的仓库
sed -i 's|YOUR_USER/YOUR_REPO|YOUR_USER/YOUR_REPO|' /root/chat-backup.sh

# 5. 一键设置（恢复数据 + 启动守护进程 + 配置 .bashrc）
/root/chat-backup.sh setup
```

> ⚠️ **请将 `YOUR_TOKEN`、`YOUR_USER`、`YOUR_REPO` 替换为你自己的值！**

### 第三步：验证

```bash
# 查看备份状态
/root/chat-backup.sh status
```

预期输出：
```
=== 聊天备份状态 (Git) ===
本地会话: N 个
守护进程: ✅ 运行中 (PID: xxxx)
.bashrc: ✅
仓库: ✅ /root/chat-backup-new
最新提交: xxxxxxx Backup: 2024-xx-xx xx:xx:xx
```

## 恢复后会发生什么？

执行 `setup` 后，系统自动完成：

1. **数据恢复**：从 GitHub 仓库拉取最新数据，复制到本地聊天数据目录
2. **守护进程启动**：后台进程每 120 秒自动备份一次
3. **.bashrc 配置**：新终端连接时自动恢复 + 重启守护进程

## 常见问题

### Q: 恢复后聊天历史没有立即出现？

A: 需要重新连接终端（关闭当前终端再开一个新的），.bashrc 中的恢复逻辑会在新终端启动时执行。

### Q: 守护进程没有启动？

A: 手动启动：
```bash
/root/chat-backup.sh daemon
```

### Q: git clone 报权限错误？

A: 检查 Token 是否正确，是否有 repo 权限。Token 在 GitHub Settings → Developer settings → Personal access tokens 生成。

### Q: 恢复后发现数据不是最新的？

A: 可能是容器重建前最后一次备份后有新数据未同步。这部分数据（最多 2 分钟）无法恢复，这是方案的设计限制。

## 预防措施

1. **定期检查备份状态**：`/root/chat-backup.sh status`
2. **Token 有效期**：GitHub Token 有过期时间，过期前更新
3. **仓库不要手动修改**：让备份脚本独占管理，避免冲突
