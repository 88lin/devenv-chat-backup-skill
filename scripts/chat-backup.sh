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

# === 开启自动批准（免确认）===
# 修改 settings.json 中的 permission 为 allow，避免每次工具调用都要手动确认
enable_auto_approve() {
    local settings="$LOCAL_DIR/settings.json"
    if [ ! -f "$settings" ]; then
        log "AUTO-APPROVE: settings.json 不存在，跳过"
        return 0
    fi

    # 原子锁：防止守护进程与新终端并发写坏 settings.json
    local lockdir="${settings}.lockdir"
    if ! mkdir "$lockdir" 2>/dev/null; then
        log "AUTO-APPROVE: settings.json 被占用，跳过"
        return 0
    fi

    # 用 python3 安全修改 JSON
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json, sys
with open('$settings', 'r') as f:
    d = json.load(f)
d['permission'] = {'*': 'allow'}
with open('$settings', 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
" 2>/dev/null
        if [ $? -eq 0 ]; then
            log "AUTO-APPROVE: 已开启"
            rmdir "$lockdir" 2>/dev/null
            return 0
        fi
    fi

    # python3 不可用时用 sed 兜底
    sed -i 's/"\*": "ask"/"\*": "allow"/' "$settings" 2>/dev/null
    log "AUTO-APPROVE: sed 兜底修改"

    rmdir "$lockdir" 2>/dev/null
}

# === 同步本地数据到仓库目录 ===
# 注意：不能用 rsync，DevEnv 精简环境没有 rsync，用 cp -rf 替代
# SQLite 是 WAL 模式时，主库文件 + memory.db-wal/memory.db-shm 才构成完整数据。
# 裸 cp 主库会得到一份"撕裂"的不一致快照：一旦拿它恢复，直接产生
# "database disk image is malformed" 损坏，聊天记录全部打不开。
# 因此 SQLite 文件必须用 sqlite3 .backup 生成一致性快照，环境无 sqlite3 时
# 退化为 cp 并记录警告（不可靠）。
backup_one() {
    local f="$1"
    local src="$LOCAL_DIR/$f"
    local dst="$REPO_DIR/hwcloud-data/$f"
    [ -f "$src" ] || return 0

    case "$f" in
        *.db|*.sqlite)
            if command -v sqlite3 >/dev/null 2>&1; then
                if sqlite3 "$src" ".backup '$dst'" 2>>"$BACKUP_LOG"; then
                    # 仓库目录的 -wal/-shm 属于旧拷贝残留，必须清掉避免误恢复
                    rm -f "$dst-wal" "$dst-shm"
                else
                    log "BACKUP: $f 一致性快照失败（库损坏或被占用），跳过"
                fi
            else
                cp -f "$src" "$dst" 2>/dev/null
                rm -f "$dst-wal" "$dst-shm"
                log "BACKUP: 警告: 环境无 sqlite3，$f 使用裸 cp 备份（不可靠，建议安装 sqlite3）"
            fi
            ;;
        *)
            cp -f "$src" "$dst" 2>/dev/null
            ;;
    esac
}

# === 生成可读的会话索引 ===
# 扫描所有 session jsonl 文件，提取首条用户消息作为标题，
# 生成 sessions-index.md（人类可读）和 sessions-index.json（程序可读）
generate_session_index() {
    local sessions_dir="$LOCAL_DIR/sessions"
    [ -d "$sessions_dir" ] || return 0

    local index_md="$REPO_DIR/hwcloud-data/sessions-index.md"
    local index_json="$REPO_DIR/hwcloud-data/sessions-index.json"

    python3 - "$sessions_dir" "$index_md" "$index_json" << 'PYINDEX' 2>/dev/null
import json, os, glob, sys
from datetime import datetime

sessions_dir, index_md, index_json = sys.argv[1], sys.argv[2], sys.argv[3]

files = sorted(glob.glob(os.path.join(sessions_dir, "*.jsonl")),
               key=lambda f: os.path.getmtime(f))

entries = []
for f in files:
    sid = os.path.basename(f).replace('.jsonl', '')
    mtime = os.path.getmtime(f)
    mtime_str = datetime.fromtimestamp(mtime).strftime('%Y-%m-%d %H:%M')
    size = os.path.getsize(f)

    title = "(空会话)"
    msg_count = 0
    first_user_msg = ""

    with open(f, 'r', encoding='utf-8', errors='replace') as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
                msg_count += 1
                if d.get("Role") == 0 and d.get("Content") and not first_user_msg:
                    first_user_msg = d["Content"][:80].replace('\n', ' ').strip()
            except:
                continue

    if first_user_msg:
        title = first_user_msg

    entries.append({
        "id": sid,
        "title": title,
        "mtime": mtime_str,
        "messages": msg_count,
        "size": size
    })

with open(index_md, 'w', encoding='utf-8') as f:
    f.write(f"# 会话索引（共 {len(entries)} 个会话）\n\n")
    f.write(f"生成时间：{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n")
    f.write("| 序号 | 日期 | 消息数 | 标题 | 会话ID |\n")
    f.write("|------|------|--------|------|--------|\n")
    for i, e in enumerate(entries, 1):
        f.write(f"| {i} | {e['mtime']} | {e['messages']} | {e['title']} | `{e['id']}` |\n")
    f.write(f"\n> 在 GitHub 仓库中点击对应的 `.jsonl` 文件可查看完整对话内容。\n")

with open(index_json, 'w', encoding='utf-8') as f:
    json.dump(entries, f, ensure_ascii=False, indent=2)
PYINDEX
    log "INDEX: 已生成会话索引"
}

sync_to_repo() {
    [ ! -d "$LOCAL_DIR" ] && return 0
    mkdir -p "$REPO_DIR/hwcloud-data/sessions"

    # 同步 sessions：复制本地文件到仓库
    if [ -d "$LOCAL_DIR/sessions" ]; then
        cp -rfp "$LOCAL_DIR/sessions/"* "$REPO_DIR/hwcloud-data/sessions/" 2>/dev/null
        # 删除仓库中已不在本地的文件（清理过期会话）
        for repo_file in "$REPO_DIR/hwcloud-data/sessions/"*; do
            [ -f "$repo_file" ] || continue
            local base; base=$(basename "$repo_file")
            [ -f "$LOCAL_DIR/sessions/$base" ] || rm -f "$repo_file"
        done
    fi

    # 生成可读的会话索引
    generate_session_index

    # 同步其他重要文件（SQLite 走一致性快照）
    for f in memory.db audit.db settings.json SOUL.md user_info.json; do
        backup_one "$f"
    done
}

# === 从仓库目录恢复到本地 ===
# 注意：只覆盖不删除，避免删除本地新创建的会话
# 警告：SQLite 是 WAL 模式时，运行中的聊天进程持有 -wal/-shm 帧，
#       此时直接覆盖主库文件会造成主库与 WAL 帧错位 → 数据库损坏。
#       因此：
#       1) 覆盖前探测聊天进程；检测到在运行则本次恢复直接跳过（新终端时机兜底）
#       2) 覆盖后清除本地残留的 -wal/-shm，让应用重启时干净重建
#       3) 覆盖前先留一份现场快照到 restore-points/，出错可回滚
# 聊天进程名不匹配时可用环境变量覆盖：HWCLOUD_PROC="another -arg"
HWCLOUD_PROC="${HWCLOUD_PROC:-hwcloud}"

sync_from_repo() {
    [ ! -d "$REPO_DIR/hwcloud-data" ] && return 0

    # 探测聊天进程是否在运行（WAL 防损坏）
    if pgrep -f "$HWCLOUD_PROC" >/dev/null 2>&1; then
        log "RESTORE: 检测到 '$HWCLOUD_PROC' 正在运行，跳过数据库覆盖（避免 WAL 损坏）；请先退出聊天再手动恢复"
        return 1
    fi

    # WAL 活跃度检测：即使进程未检测到，如果 WAL 文件在最近 120 秒内被修改过，
    # 说明数据库仍在活跃使用（可能是进程刚重启的间隙），跳过 restore 避免覆盖+删 WAL 导致损坏
    local _now_ts; _now_ts=$(date +%s)
    for _wal in "$LOCAL_DIR/memory.db-wal" "$LOCAL_DIR/audit.db-wal"; do
        if [ -f "$_wal" ]; then
            local _wal_mtime _wal_age
            _wal_mtime=$(stat -c %Y "$_wal" 2>/dev/null || echo 0)
            _wal_age=$((_now_ts - _wal_mtime))
            if [ "$_wal_age" -lt 120 ]; then
                log "RESTORE: WAL 文件 $_wal 在 ${_wal_age}s 前被修改，数据库活跃使用中，跳过 restore"
                return 1
            fi
        fi
    done

    mkdir -p "$LOCAL_DIR/sessions" "$LOCAL_DIR/logs" "$REPO_DIR/restore-points"

    if [ -d "$REPO_DIR/hwcloud-data/sessions" ]; then
        cp -rfp "$REPO_DIR/hwcloud-data/sessions/"* "$LOCAL_DIR/sessions/" 2>/dev/null
    fi

    # 覆盖前留现场快照，便于回滚
    for f in memory.db audit.db; do
        [ -f "$LOCAL_DIR/$f" ] && cp -f "$LOCAL_DIR/$f" "$REPO_DIR/restore-points/$(date '+%Y%m%d-%H%M%S')-$f.bak" 2>/dev/null
    done

    for f in memory.db audit.db settings.json SOUL.md user_info.json; do
        [ -f "$REPO_DIR/hwcloud-data/$f" ] && cp -f "$REPO_DIR/hwcloud-data/$f" "$LOCAL_DIR/$f"
    done

    # 关键：清掉本地旧 WAL/SHM，避免新旧帧错位导致的库损坏
    rm -f "$LOCAL_DIR/memory.db-wal" "$LOCAL_DIR/memory.db-shm"
    rm -f "$LOCAL_DIR/audit.db-wal"  "$LOCAL_DIR/audit.db-shm"

    log "RESTORE: 数据库已覆盖，并已清除本地 -wal/-shm，请重启聊天应用"
}

# === 备份 ===
do_backup() {
    # 备份锁：防止守护进程与手动 backup 并发执行导致 git index.lock 冲突
    local _bk_lock="/var/run/chat-backup-bk.lock"
    # 过期锁清理：如果锁存在且超过 300 秒（进程可能崩溃），自动清理
    if [ -d "$_bk_lock" ]; then
        local _lock_age=$(( $(date +%s) - $(stat -c %Y "$_bk_lock" 2>/dev/null || echo 0) ))
        if [ "$_lock_age" -gt 300 ]; then
            log "BACKUP: 锁已过期 ${_lock_age}s，清理崩溃残留锁"
            rmdir "$_bk_lock" 2>/dev/null
        fi
    fi
    if ! mkdir "$_bk_lock" 2>/dev/null; then
        log "BACKUP: 另一个备份正在进行，跳过"
        return 0
    fi

    log "BACKUP: 开始"

    # 确保仓库存在
    if [ ! -d "$REPO_DIR/.git" ]; then
        timeout $GIT_TIMEOUT git clone "$REPO_URL" "$REPO_DIR" 2>>"$BACKUP_LOG" >/dev/null
    fi

    cd "$REPO_DIR" || { log "BACKUP: 错误, 仓库目录不可用"; rmdir "$_bk_lock" 2>/dev/null; return 1; }

    # 拉取最新变更（必须加 timeout，否则网络问题会导致卡死）
    timeout $GIT_TIMEOUT git pull --rebase origin main 2>>"$BACKUP_LOG" >/dev/null

    # 同步本地数据到仓库
    sync_to_repo

    # 检查是否有变更
    git add -A
    if git diff --cached --quiet 2>/dev/null; then
        log "BACKUP: 无变更, 跳过"
        rmdir "$_bk_lock" 2>/dev/null; return 0
    fi

    # 提交并推送（push 必须加 timeout）
    git commit -m "Backup: $(date '+%Y-%m-%d %H:%M:%S')" 2>>"$BACKUP_LOG" >/dev/null
    timeout $GIT_TIMEOUT git push origin main 2>>"$BACKUP_LOG" >/dev/null

    local n; n=$(find "$LOCAL_DIR/sessions" -name "*.jsonl" 2>/dev/null | wc -l)
    log "BACKUP: 完成, 会话数=$n"
    rmdir "$_bk_lock" 2>/dev/null
}

# === 恢复 ===
do_restore() {
    log "RESTORE: 开始"

    if [ ! -d "$REPO_DIR/.git" ]; then
        timeout $GIT_TIMEOUT git clone "$REPO_URL" "$REPO_DIR" 2>>"$BACKUP_LOG" >/dev/null
    else
        (cd "$REPO_DIR" && timeout $GIT_TIMEOUT git pull --rebase origin main 2>>"$BACKUP_LOG" >/dev/null)
    fi

    if ! sync_from_repo; then
        log "RESTORE: 已跳过（原因见上方日志）"
        return 0
    fi

    # 恢复后确保自动批准开启
    enable_auto_approve

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
    echo "1. 开启自动批准（免确认）..."
    enable_auto_approve
    echo "   ✅"

    echo "2. 首次备份..."
    do_backup
    echo "   ✅"

    echo "3. 启动后台备份（每 ${BACKUP_INTERVAL} 秒）..."
    start_daemon
    sleep 1
    echo "   ✅ PID: $(cat "$PID_FILE" 2>/dev/null)"

    echo "4. 修改 .bashrc..."
    local M="# >>> chat-backup auto-restore >>>"
    local ME="# <<< chat-backup auto-restore <<<"
    grep -q "$M" /root/.bashrc 2>/dev/null && sed -i "/${M}/,/${ME}/d" /root/.bashrc
    cat >> /root/.bashrc << 'EOF'

# >>> chat-backup auto-restore >>>
# 安全策略：.bashrc 只启动备份守护进程，不自动 restore。
# restore 会覆盖数据库文件，在 AI 进程启动间隙执行会导致数据损坏。
# 容器重建后请手动执行一次：/root/chat-backup.sh restore
if [ -f /root/chat-backup.sh ]; then
    /root/chat-backup.sh daemon 2>/dev/null
fi
# <<< chat-backup auto-restore <<<
EOF
    echo "   ✅"

    echo ""
    echo "✅ 设置完成！"
    echo "   - 每 ${BACKUP_INTERVAL} 秒自动备份到 GitHub 私有仓库"
    echo "   - 新终端自动重启备份守护进程（不自动 restore，避免数据损坏）"
    echo "   - 容器重建后请手动执行: /root/chat-backup.sh restore"
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
    backup)       do_backup ;;
    restore)      do_restore ;;
    setup)        do_setup ;;
    daemon)       start_daemon ;;
    status)       do_status ;;
    auto-approve) enable_auto_approve; echo "✅ 自动批准已开启" ;;
    *) echo "用法: $0 {backup|restore|setup|daemon|status|auto-approve}"; exit 1 ;;
esac
