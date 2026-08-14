# 踩坑经验汇总

在实际 DevEnv 环境中部署聊天备份方案时踩过的所有坑，以及对应的解决方案。

---

## 坑 1：rsync 不可用

**现象**：脚本中使用 `rsync` 同步文件，报错 `rsync: command not found`

**原因**：DevEnv 是精简容器环境，没有安装 rsync

**解决**：用 `cp -rf` 替代 rsync

```bash
# ❌ 不可用
rsync -av --delete "$LOCAL_DIR/sessions/" "$REPO_DIR/sessions/"

# ✅ 替代方案
cp -rf "$LOCAL_DIR/sessions/"* "$REPO_DIR/sessions/"
# 清理过期文件需要手动遍历删除
for repo_file in "$REPO_DIR/sessions/"*; do
    [ -f "$repo_file" ] || continue
    base=$(basename "$repo_file")
    [ -f "$LOCAL_DIR/sessions/$base" ] || rm -f "$repo_file"
done
```

---

## 坑 2：git 命令无超时会卡死

**现象**：守护进程运行一段时间后停止工作，`ps` 显示 git 进程处于 `D` 状态（不可中断睡眠）

**原因**：网络抖动时 `git push` / `git pull` 会无限等待，没有超时机制

**解决**：所有 git 命令用 `timeout` 包裹

```bash
GIT_TIMEOUT=30

# ❌ 危险：网络问题会无限卡死
git pull origin main
git push origin main

# ✅ 安全：30秒超时
timeout $GIT_TIMEOUT git pull origin main
timeout $GIT_TIMEOUT git push origin main
```

---

## 坑 3：守护进程 CWD（工作目录）丢失

**现象**：守护进程运行一段时间后报 `fatal: not a git repository`

**原因**：守护进程的工作目录（CWD）可能被删除或重建，导致 git 命令找不到仓库

**解决**：守护进程启动时先 `cd /root`，每次 backup 时也确保 cd 到仓库目录

```bash
# ❌ 依赖当前目录
nohup bash -c "while true; do ./chat-backup.sh backup; sleep 120; done" &

# ✅ 显式 cd 到稳定目录
nohup setsid bash -c "cd /root; while true; do /root/chat-backup.sh backup; sleep 120; done" &
```

---

## 坑 4：crontab 不可用

**现象**：`crontab -e` 报错，无法设置定时任务

**原因**：DevEnv 精简环境没有 cron 服务

**解决**：用 `setsid + nohup + while 循环` 替代 crontab

```bash
# ❌ 不可用
crontab -e
# */2 * * * * /root/chat-backup.sh backup

# ✅ 替代方案：后台守护进程
nohup setsid bash -c "
    cd /root
    echo \$\$ > /var/run/chat-backup.pid
    while true; do
        /root/chat-backup.sh backup
        sleep 120
    done
" >/dev/null 2>&1 &
```

---

## 坑 5：curl 被 DNS 限制

**现象**：`curl https://raw.githubusercontent.com/...` 超时，但 `git clone` 正常

**原因**：DevEnv 网络环境对 `raw.githubusercontent.com` 域名有 DNS 限制

**解决**：恢复命令必须用 `git clone`，不能用 curl 下载单文件

```bash
# ❌ 不可用：DNS 解析超时
curl -o chat-backup.sh https://raw.githubusercontent.com/user/repo/main/chat-backup.sh

# ✅ 可用：git clone 不受影响
git clone https://TOKEN@github.com/user/repo.git /root/chat-backup-new
cp /root/chat-backup-new/chat-backup.sh /root/chat-backup.sh
```

---

## 坑 6：.bashrc 在 overlay 层，容器重建后丢失

**现象**：容器重建后 `.bashrc` 中的自动恢复配置消失，需要重新配置

**原因**：`.bashrc` 修改写入 overlay 层，容器重建时 overlay 层被清除

**解决**：这是 overlay FS 的设计特性，无法避免。方案是将恢复命令保存到 GitHub 仓库的 README 中，容器重建后手动执行一次即可

```bash
# .bashrc 中添加的自动恢复逻辑（容器重建后会丢失）
# >>> chat-backup auto-restore >>>
if [ -f /root/chat-backup.sh ]; then
    /root/chat-backup.sh restore 2>/dev/null
    /root/chat-backup.sh daemon 2>/dev/null
fi
# <<< chat-backup auto-restore <<<

# 容器重建后手动执行一次恢复命令（从 GitHub 仓库 README 复制）
git config --global credential.helper store
echo "https://YOUR_TOKEN@github.com" > ~/.git-credentials
git clone https://YOUR_TOKEN@github.com/YOUR_USER/YOUR_REPO.git /root/chat-backup-new
cp /root/chat-backup-new/chat-backup.sh /root/chat-backup.sh
chmod +x /root/chat-backup.sh
/root/chat-backup.sh setup
```

---

## 坑 7：git 等待输入导致守护进程卡死

**现象**：守护进程静默停止，没有错误日志

**原因**：git 在某些情况下会等待用户输入（如认证失败时提示输入密码），守护进程没有 TTY，会无限等待

**解决**：设置 `GIT_TERMINAL_PROMPT=0`，git 遇到需要输入时直接报错退出而不是等待

```bash
# ✅ 在脚本开头设置
export GIT_TERMINAL_PROMPT=0
```

---

## 坑 8：僵尸 git 进程堆积 + index.lock 冲突

**现象**：系统出现大量 `D` 状态的 git 进程，新备份报 `index.lock exists` 错误

**原因**：
1. 网络问题导致 git 进程卡在 `D` 状态（不可中断睡眠）
2. 卡死的 git 进程持有 `index.lock`，新 git 命令无法执行
3. 守护进程不断启动新 git 命令，进程越积越多

**解决**：
1. 用 `timeout` 防止 git 无限等待（见坑 2）
2. 如果已经出现僵尸进程，手动清理：

```bash
# 杀掉所有 git 进程
pkill -9 git 2>/dev/null

# 清理 index.lock
find /root -name ".git" -type d -exec rm -f {}/index.lock \; 2>/dev/null

# 重启守护进程
/root/chat-backup.sh daemon
```

---

## 经验总结

1. **容器环境 ≠ 完整 Linux**：很多常用工具（rsync、crontab、curl 某些域名）可能不可用，要有替代方案
2. **网络不可靠**：所有网络操作必须加超时，否则守护进程会卡死
3. **overlay 层是临时的**：任何写入 overlay 层的配置（.bashrc 等）都可能在容器重建后丢失
4. **守护进程要自防御**：CWD 丢失、TTY 缺失、进程堆积等问题都要预防
5. **恢复命令要外部保存**：恢复命令本身也在 overlay 层，容器重建后一起丢失，必须保存到外部（如 GitHub 仓库 README）
