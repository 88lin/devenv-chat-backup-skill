#!/bin/bash
# chat-backup.sh — 聊天历史自动备份/恢复脚本（Git 版）
# 使用 GitHub 私有仓库做备份，完全免费
#
# === 用法 ===
#   chat-backup.sh setup     # 首次设置：备份 + 启动守护进程 + 配置 .bashrc
#   chat-backup.sh backup    # 备份当前数据到 Git
#   chat-backup.sh restore   # 从 Git 恢复最新数据
#   chat-backup.sh daemon    # 启动后台守护进程（每120秒备份）
#   chat-backup.sh status    # 查看备份状态
#
# === 配置 ===
# 使用前请修改以下变量：
#   REPO_URL  — 你的 GitHub 私有仓库地址
#   REPO_DIR  — 本地仓库克隆路径
#   LOCAL_DIR — 需要备份的数据目录

# ==================== 配置区（请修改） ====================
REPO_URL="https://github.com/YOUR_USER/devenv-chat-backup.git"
REPO_DIR="/root/chat-backup-new"
LOCAL_DIR="/root/.huawei/hwcloud"          # DevEnv 聊天数据目录
SCRIPT_PATH="/root/chat-backup.sh"
BACKUP_LOG="/var/log/chat-backup.log"
PID_FILE="/var/run/chat-backup.pid"
BACKUP_INTERVAL=120                        # 备份间隔（秒）
GIT_TIMEOUT=30                             # git 命令超时（秒）
# ==========================================================

# 防止 git 等待输入（关键！不加会导致守护进程卡死）
export GIT_TERMINAL_PROMPT=0

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$BACKUP_LOG" 2>/dev/null; }

# === 同步本地数据到仓库目录 ===
# 注意：不能用 rsync，DevEnv 精简环境没有 rsync，用 cp -rf 替代
sync_to_repo() {
    [ ! -d "$LOCAL_DIR" ] && return 0
    mkdir -p "$REPO_DIR/hwcloud-data/sessions"

    # 同步 sessions：复制本地文件到仓库
    if [ -d "$LOCAL_DIR/sessions" ]; then
        cp -rf "$LOCAL_DIR/sessions/"* "$REPO_DIR/hwcloud-data/sessions/" 2>/dev/null
        # 删除仓库中已不在本地的文件（清理过期会话）
        for repo_file in "$REPO_DIR/hwcloud-data/sessions/"*; do
            [ -f "$repo_file" ] || continue
            local base; base=$(basename "$repo_file")
            [ -f "$LOCAL_DIR/sessions/$base" ] || rm -f "$repo_file"
        done
    fi

    # 同步其他重要文件
    for f in memory.db audit.db settings.json SOUL.md user_info.json; do
        [ -f "$LOCAL_DIR/$f" ] && cp -f "$LOCAL_DIR/$f" "$REPO_DIR/hwcloud-data/$f"
    done
}

# === 从仓库目录恢复到本地 ===
# 注意：只覆盖不删除，避免删除本地新创建的会话
sync_from_repo() {
    [ ! -d "$REPO_DIR/hwcloud-data" ] && return 0
    mkdir -p "$LOCAL_DIR/sessions" "$LOCAL_DIR/logs"

    if [ -d "$REPO_DIR/hwcloud-data/sessions" ]; then
        cp -rf "$REPO_DIR/hwcloud-data/sessions/"* "$LOCAL_DIR/sessions/" 2>/dev/null
    fi

    for f in memory.db audit.db settings.json SOUL.md user_info.json; do
        [ -f "$REPO_DIR/hwcloud-data/$f" ] && cp -f "$REPO_DIR/hwcloud-data/$f" "$LOCAL_DIR/$f"
    done
}

# === 备份 ===
do_backup() {
    log "BACKUP: 开始"

    # 确保仓库存在
    if [ ! -d "$REPO_DIR/.git" ]; then
        timeout $GIT_TIMEOUT git clone "$REPO_URL" "$REPO_DIR" 2>>"$BACKUP_LOG" >/dev/null
    fi

    cd "$REPO_DIR" || { log "BACKUP: 错误, 仓库目录不可用"; return 1; }

    # 拉取最新变更（必须加 timeout，否则网络问题会导致卡死）
    timeout $GIT_TIMEOUT git pull --rebase origin main 2>>"$BACKUP_LOG" >/dev/null

    # 同步本地数据到仓库
    sync_to_repo

    # 检查是否有变更
    git add -A
    if git diff --cached --quiet 2>/dev/null; then
        log "BACKUP: 无变更, 跳过"
        return 0
    fi

    # 提交并推送（push 必须加 timeout）
    git commit -m "Backup: $(date '+%Y-%m-%d %H:%M:%S')" 2>>"$BACKUP_LOG" >/dev/null
    timeout $GIT_TIMEOUT git push origin main 2>>"$BACKUP_LOG" >/dev/null

    local n; n=$(find "$LOCAL_DIR/sessions" -name "*.jsonl" 2>/dev/null | wc -l)
    log "BACKUP: 完成, 会话数=$n"
}

# === 恢复 ===
do_restore() {
    log "RESTORE: 开始"

    if [ ! -d "$REPO_DIR/.git" ]; then
        timeout $GIT_TIMEOUT git clone "$REPO_URL" "$REPO_DIR" 2>>"$BACKUP_LOG" >/dev/null
    else
        (cd "$REPO_DIR" && timeout $GIT_TIMEOUT git pull --rebase origin main 2>>"$BACKUP_LOG" >/dev/null)
    fi

    sync_from_repo

    local n; n=$(find "$LOCAL_DIR/sessions" -name "*.jsonl" 2>/dev/null | wc -l)
    log "RESTORE: 完成, 会话数=$n"
}

# === 后台守护进程 ===
# 注意：crontab 在 DevEnv 不可用，用 setsid + nohup + while 循环替代
start_daemon() {
    # 先杀掉旧进程
    if [ -f "$PID_FILE" ]; then
        local old_pid; old_pid=$(cat "$PID_FILE" 2>/dev/null)
        [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null && kill "$old_pid" 2>/dev/null
    fi

    # 启动后台循环
    # 关键：cd /root 防止 CWD 丢失（仓库目录可能被删除导致 git 命令失败）
    nohup setsid bash -c "cd /root; echo \$\$ > '$PID_FILE'; while true; do '$SCRIPT_PATH' backup; sleep $BACKUP_INTERVAL; done" >/dev/null 2>&1 &
    log "DAEMON: 已启动"
}

# === 首次设置 ===
do_setup() {
    echo "1. 首次备份..."
    do_backup
    echo "   ✅"

    echo "2. 启动后台备份（每 ${BACKUP_INTERVAL} 秒）..."
    start_daemon
    sleep 1
    echo "   ✅ PID: $(cat "$PID_FILE" 2>/dev/null)"

    echo "3. 修改 .bashrc..."
    local M="# >>> chat-backup auto-restore >>>"
    local ME="# <<< chat-backup auto-restore <<<"
    grep -q "$M" /root/.bashrc 2>/dev/null && sed -i "/${M}/,/${ME}/d" /root/.bashrc
    cat >> /root/.bashrc << 'EOF'

# >>> chat-backup auto-restore >>>
if [ -f /root/chat-backup.sh ]; then
    /root/chat-backup.sh restore 2>/dev/null
    /root/chat-backup.sh daemon 2>/dev/null
fi
# <<< chat-backup auto-restore <<<
EOF
    echo "   ✅"

    echo ""
    echo "✅ 设置完成！"
    echo "   - 每 ${BACKUP_INTERVAL} 秒自动备份到 GitHub 私有仓库"
    echo "   - 新终端自动恢复 + 重启备份守护进程"
    echo "   - 备份日志: $BACKUP_LOG"
}

# === 状态 ===
do_status() {
    echo "=== 聊天备份状态 (Git) ==="
    local n; n=$(find "$LOCAL_DIR/sessions" -name "*.jsonl" 2>/dev/null | wc -l)
    echo "本地会话: $n 个"

    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
        echo "守护进程: ✅ 运行中 (PID: $(cat "$PID_FILE"))"
    else
        echo "守护进程: ❌ 未运行"
    fi

    grep -q "chat-backup" /root/.bashrc 2>/dev/null && echo ".bashrc: ✅" || echo ".bashrc: ❌"

    if [ -d "$REPO_DIR/.git" ]; then
        echo "仓库: ✅ $REPO_DIR"
        (cd "$REPO_DIR" && echo "最新提交: $(git log --oneline -1 2>/dev/null)")
    else
        echo "仓库: ❌ 未克隆"
    fi

    echo ""
    echo "最近日志:"
    tail -5 "$BACKUP_LOG" 2>/dev/null || echo "  (无日志)"
}

# === 主逻辑 ===
case "${1:-}" in
    backup)  do_backup ;;
    restore) do_restore ;;
    setup)   do_setup ;;
    daemon)  start_daemon ;;
    status)  do_status ;;
    *) echo "用法: $0 {backup|restore|setup|daemon|status}"; exit 1 ;;
esac
