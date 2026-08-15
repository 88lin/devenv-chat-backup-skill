#!/bin/bash
# chat-backup.sh - 聊天历史自动备份/恢复脚本（Git 版）
# 使用 GitHub 私有仓库做备份，完全免费
#
# 用法:
#   chat-backup.sh backup    # 备份当前数据到 Git
#   chat-backup.sh restore   # 从 Git 恢复最新数据（手动执行，不要放 .bashrc）
#   chat-backup.sh setup     # 设置后台定时备份 + .bashrc 自动备份守护进程
#   chat-backup.sh daemon    # 启动后台备份守护进程
#   chat-backup.sh status    # 查看备份状态

# === 配置 ===
REPO_URL="https://github.com/88lin/devenv-chat-backup.git"
REPO_DIR="/root/chat-backup-new"
LOCAL_DIR="/root/.huawei/hwcloud"
SCRIPT_PATH="/root/chat-backup.sh"
BACKUP_LOG="/var/log/chat-backup.log"
PID_FILE="/var/run/chat-backup.pid"
BACKUP_INTERVAL=120  # 备份间隔（秒）
GIT_TIMEOUT=30       # git 命令超时（秒）
LOCK_DIR="/var/run/chat-backup.lock"
STALE_LOCK_SEC=300   # 锁超过 300 秒视为过期（崩溃/OOM 恢复）

# 防止 git 等待输入
export GIT_TERMINAL_PROMPT=0

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$BACKUP_LOG" 2>/dev/null; }

# === 备份锁（防止并发 backup 导致 index.lock 冲突）===
acquire_lock() {
    # 清理过期锁
    if [ -d "$LOCK_DIR" ]; then
        local lock_age; lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0) ))
        if [ "$lock_age" -gt "$STALE_LOCK_SEC" ]; then
            rmdir "$LOCK_DIR" 2>/dev/null
            log "LOCK: 清理过期锁 (${lock_age}s)"
        fi
    fi
    mkdir "$LOCK_DIR" 2>/dev/null || { log "LOCK: 已有备份在进行中，跳过"; return 1; }
    return 0
}

release_lock() {
    rmdir "$LOCK_DIR" 2>/dev/null
}

# === SQLite 一致性备份 ===
sqlite_backup() {
    local src="$1" dst="$2"
    if [ -f "$src" ] && command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 "$src" ".backup '$dst'" 2>/dev/null
    elif [ -f "$src" ]; then
        cp -f "$src" "$dst"
    fi
}

# === 生成可读的会话索引 ===
# 扫描所有 session jsonl 文件，提取首条用户消息作为标题，
# 生成 sessions-index.md（人类可读）和 sessions-index.json（程序可读）
generate_session_index() {
    local sessions_dir="$LOCAL_DIR/sessions"
    [ -d "$sessions_dir" ] || return 0

    local index_md="$REPO_DIR/hwcloud-data/sessions-index.md"
    local index_json="$REPO_DIR/hwcloud-data/sessions-index.json"
    local db_path="$LOCAL_DIR/memory.db"

    python3 - "$sessions_dir" "$index_md" "$index_json" "$db_path" << 'PYEOF' 2>/dev/null
import json, os, glob, sys, sqlite3
from datetime import datetime

sessions_dir, index_md, index_json, db_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

# 从数据库读取会话创建时间（start_timestamp）
db_times = {}
try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=3)
    cur = conn.cursor()
    cur.execute("SELECT session_id, start_timestamp FROM sessions")
    for sid, ts in cur.fetchall():
        if ts:
            db_times[sid] = datetime.fromtimestamp(ts).strftime('%Y-%m-%d %H:%M')
    conn.close()
except:
    pass

files = sorted(glob.glob(os.path.join(sessions_dir, "*.jsonl")),
               key=lambda f: os.path.getmtime(f))

entries = []
for f in files:
    sid = os.path.basename(f).replace('.jsonl', '')
    # 优先用数据库的会话创建时间，回退到文件 mtime
    if sid in db_times:
        time_str = db_times[sid]
    else:
        mtime = os.path.getmtime(f)
        time_str = datetime.fromtimestamp(mtime).strftime('%Y-%m-%d %H:%M')
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
        "date": time_str,
        "messages": msg_count,
        "size": size
    })

# 按时间排序
entries.sort(key=lambda e: e["date"])

# 生成 Markdown 索引
with open(index_md, 'w', encoding='utf-8') as f:
    f.write(f"# 会话索引（共 {len(entries)} 个会话）\n\n")
    f.write(f"生成时间：{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n")
    f.write("| 序号 | 日期 | 消息数 | 标题 | 会话ID |\n")
    f.write("|------|------|--------|------|--------|\n")
    for i, e in enumerate(entries, 1):
        f.write(f"| {i} | {e['date']} | {e['messages']} | {e['title']} | `{e['id']}` |\n")
    f.write(f"\n> 在 GitHub 仓库中点击对应的 `.jsonl` 文件可查看完整对话内容。\n")

# 生成 JSON 索引
with open(index_json, 'w', encoding='utf-8') as f:
    json.dump(entries, f, ensure_ascii=False, indent=2)

PYEOF
    log "INDEX: 已生成会话索引 ($index_md)"
}

# === 同步本地数据到仓库目录 ===
sync_to_repo() {
    [ ! -d "$LOCAL_DIR" ] && return 0
    mkdir -p "$REPO_DIR/hwcloud-data/sessions"

    # 同步 sessions（-p 保留原始时间戳，不再全部变成备份时间）
    if [ -d "$LOCAL_DIR/sessions" ]; then
        cp -rfp "$LOCAL_DIR/sessions/"* "$REPO_DIR/hwcloud-data/sessions/" 2>/dev/null
        # 删除仓库中已不在本地的文件（清理过期会话）
        for repo_file in "$REPO_DIR/hwcloud-data/sessions/"*; do
            [ -f "$repo_file" ] || continue
            local base; base=$(basename "$repo_file")
            [ -f "$LOCAL_DIR/sessions/$base" ] || rm -f "$repo_file"
        done
    fi

    # 生成可读的会话索引（解决"全是数字英文看不出哪个是哪个"的问题）
    generate_session_index

    # 同步数据库（用 sqlite3 .backup 保证一致性，不裸拷 WAL 库）
    sqlite_backup "$LOCAL_DIR/memory.db" "$REPO_DIR/hwcloud-data/memory.db"
    sqlite_backup "$LOCAL_DIR/audit.db" "$REPO_DIR/hwcloud-data/audit.db"

    # 同步其他文件
    for f in settings.json SOUL.md user_info.json; do
        [ -f "$LOCAL_DIR/$f" ] && cp -f "$LOCAL_DIR/$f" "$REPO_DIR/hwcloud-data/$f"
    done
}

# === 安全合并会话数据库（AI 运行时也能用）===
# 用 SQLite ATTACH + INSERT OR REPLACE 把备份的会话记录合并到当前数据库
# 这样即使 AI 进程在运行，也能安全恢复会话标题，不会损坏数据库
merge_session_db() {
    local backup_db="$1"   # 备份的 memory.db 路径
    local live_db="$2"     # 当前正在用的 memory.db 路径
    [ -f "$backup_db" ] || return 0
    [ -f "$live_db" ] || return 0
    command -v sqlite3 >/dev/null 2>&1 || return 0

    # 复制备份数据库到临时文件（避免直接 ATTACH 时的锁问题）
    local tmp_db="/tmp/backup_merge_$$.db"
    cp -f "$backup_db" "$tmp_db" 2>/dev/null

    # 用 ATTACH + INSERT OR REPLACE 合并 sessions（含标题）和 messages
    sqlite3 "$live_db" "$(printf "ATTACH DATABASE '%s' AS bk;\nINSERT OR REPLACE INTO sessions SELECT * FROM bk.sessions;\nINSERT OR IGNORE INTO messages (message_uid, session_id, role, content_json, search_text, tool_name, tool_call_id, tool_calls, finish_reason, reasoning, timestamp, token_count) SELECT message_uid, session_id, role, content_json, search_text, tool_name, tool_call_id, tool_calls, finish_reason, reasoning, timestamp, token_count FROM bk.messages;\nDETACH DATABASE bk;\n" "$tmp_db")" 2>/dev/null

    local rc=$?
    rm -f "$tmp_db"

    if [ $rc -eq 0 ]; then
        local n; n=$(sqlite3 "$live_db" "SELECT COUNT(*) FROM sessions WHERE title != '';" 2>/dev/null || echo 0)
        log "MERGE: 数据库合并完成, 有标题的会话=$n"
    else
        log "MERGE: 数据库合并失败 (exit=$rc)"
    fi
    return $rc
}

# === 从 .jsonl 文件补充 messages 表 ===
# DevEnv 界面从 messages 表读取会话显示名（第一条用户消息）
# 容器重建后 messages 表可能为空，需要从 .jsonl 文件补充
# 同时用 TurnId 线性插值恢复会话时间戳（解决重建后时间全一样的问题）
import_messages_from_jsonl() {
    [ -d "$LOCAL_DIR/sessions" ] || return 0
    [ -f "$LOCAL_DIR/memory.db" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0

    python3 - "$LOCAL_DIR" <<'PYEOF' 2>/dev/null
import json, os, sqlite3, time, uuid, sys

local_dir = sys.argv[1]
sessions_dir = os.path.join(local_dir, "sessions")
db_path = os.path.join(local_dir, "memory.db")

ROLE_MAP = {0: "user", 1: "assistant", 2: "tool", 3: "assistant"}

def gen_uid():
    return "01" + uuid.uuid4().hex.upper()[:24]

conn = sqlite3.connect(db_path)
conn.execute("PRAGMA journal_mode=WAL")
cur = conn.cursor()

cur.execute("SELECT session_id, start_timestamp FROM sessions")
sessions = cur.fetchall()

imported = 0
for session_id, start_ts in sessions:
    cur.execute("SELECT COUNT(*) FROM messages WHERE session_id=?", (session_id,))
    if cur.fetchone()[0] > 0:
        continue

    jsonl_path = os.path.join(sessions_dir, f"{session_id}.jsonl")
    if not os.path.exists(jsonl_path):
        continue

    rows = []
    with open(jsonl_path, "r", encoding="utf-8") as f:
        for i, line in enumerate(f):
            line = line.strip()
            if not line:
                continue
            try:
                data = json.loads(line)
            except:
                continue
            role_num = data.get("Role", -1)
            role_str = ROLE_MAP.get(role_num, "assistant")
            content = data.get("Content", "")
            if not content:
                continue
            ts = start_ts + i * 0.001
            msg_uid = gen_uid()
            content_json = json.dumps({
                "ID": msg_uid, "SessionID": session_id, "Role": role_str,
                "Parts": [{"Type": "text", "Text": {"Text": content},
                           "File": None, "Image": None, "Audio": None,
                           "ToolCall": None, "Reasoning": None}],
                "Metadata": {"acp_message_id": None, "acp_meta": {}, "source": "local"},
                "CreatedAt": time.strftime("%Y-%m-%dT%H:%M:%S+08:00", time.localtime(ts)),
                "TokenCount": 0
            }, ensure_ascii=False)
            rows.append((msg_uid, session_id, role_str, content_json,
                        content[:200], "", "", "", "", "", ts, 0))

    if rows:
        cur.executemany(
            "INSERT OR IGNORE INTO messages (message_uid, session_id, role, "
            "content_json, search_text, tool_name, tool_call_id, tool_calls, "
            "finish_reason, reasoning, timestamp, token_count) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", rows)
        cur.execute("UPDATE sessions SET message_count=? WHERE session_id=?",
                    (len(rows), session_id))
        imported += 1

conn.commit()
conn.close()
if imported > 0:
    print(f"JSONL_IMPORT: 补充了 {imported} 个会话的 messages")
PYEOF
    local rc=$?
    [ $rc -eq 0 ] && log "JSONL_IMPORT: 从 .jsonl 补充 messages 表完成" || true

    # 用 TurnId 线性插值恢复会话时间戳（解决重建后时间全一样的问题）
    recover_session_timestamps

    return 0
}

# === 用 TurnId 恢复会话时间戳 ===
# 容器重建后所有会话的 start_timestamp 变成同一个时间
# 用 .jsonl 文件中的 TurnId（全局递增）线性插值恢复合理的不同时间
recover_session_timestamps() {
    [ -d "$LOCAL_DIR/sessions" ] || return 0
    [ -f "$LOCAL_DIR/memory.db" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0

    python3 - "$LOCAL_DIR" << 'PYEOF' 2>/dev/null
import json, os, sqlite3, glob, sys
from datetime import datetime

local_dir = sys.argv[1]
sessions_dir = os.path.join(local_dir, "sessions")
db_path = os.path.join(local_dir, "memory.db")

# 1. 收集每个会话的 TurnId
turn_ids = {}
for f in glob.glob(os.path.join(sessions_dir, "*.jsonl")):
    sid = os.path.basename(f).replace(".jsonl", "")
    try:
        with open(f, "r", encoding="utf-8", errors="replace") as fh:
            first_line = fh.readline().strip()
            if first_line:
                d = json.loads(first_line)
                turn_ids[sid] = d.get("TurnId", 0)
    except:
        pass

# 2. 从 messages 表获取有真实 CreatedAt 的会话
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute("SELECT session_id, content_json FROM messages WHERE role='user'")
real_times = {}
for sid, cj in cur.fetchall():
    if sid in real_times:
        continue
    try:
        d = json.loads(cj)
        created = d.get("CreatedAt", "")
        if created:
            dt = datetime.fromisoformat(created[:26] + "+08:00")
            real_times[sid] = dt.timestamp()
    except:
        pass

# 3. 找需要修复的会话
cur.execute("SELECT session_id, start_timestamp FROM sessions")
sessions = cur.fetchall()
need_fix = []
for sid, ts in sessions:
    if sid in real_times or sid not in turn_ids:
        continue
    need_fix.append((sid, ts, turn_ids[sid]))

if not need_fix:
    conn.close()
    exit()

# 4. 用有真实时间的会话作为插值锚点
real_with_turn = [(sid, real_times[sid], turn_ids[sid]) for sid in real_times if sid in turn_ids]
if real_with_turn:
    earliest = min(real_with_turn, key=lambda x: x[1])
    latest = max(real_with_turn, key=lambda x: x[1])
    t_min, turn_min = earliest[1], earliest[2]
    t_max, turn_max = latest[1], latest[2]
else:
    # 没有锚点，用当前时间往前推 2 小时作为范围
    now = datetime.now().timestamp()
    t_min, t_max = now - 7200, now
    turn_min = min(turn_ids.values())
    turn_max = max(turn_ids.values())

# 5. 线性插值并更新
updated = 0
for sid, old_ts, turn_id in need_fix:
    if turn_max == turn_min:
        new_ts = t_min
    else:
        ratio = (turn_id - turn_min) / (turn_max - turn_min)
        new_ts = t_min + ratio * (t_max - t_min)
    cur.execute("UPDATE sessions SET start_timestamp=? WHERE session_id=?", (new_ts, sid))
    updated += 1

conn.commit()
conn.close()
if updated > 0:
    print(f"TS_RECOVER: 恢复了 {updated} 个会话的时间戳")
PYEOF
    local rc=$?
    [ $rc -eq 0 ] && log "TS_RECOVER: 用 TurnId 恢复会话时间戳完成" || true
    return 0
}

# === 从仓库目录恢复到本地 ===
sync_from_repo() {
    [ ! -d "$REPO_DIR/hwcloud-data" ] && return 0
    mkdir -p "$LOCAL_DIR/sessions" "$LOCAL_DIR/logs"

    local ai_running=0
    pgrep -f hwcloud >/dev/null 2>&1 && ai_running=1

    if [ "$ai_running" -eq 1 ]; then
        log "RESTORE: AI 进程运行中，使用安全合并模式恢复数据库"
        # 安全合并 memory.db（会话标题 + 消息记录）
        if [ -f "$REPO_DIR/hwcloud-data/memory.db" ]; then
            merge_session_db "$REPO_DIR/hwcloud-data/memory.db" "$LOCAL_DIR/memory.db"
        fi
    else
        # AI 未运行，可以直接恢复整个数据库
        for db in memory.db audit.db; do
            wal_file="$LOCAL_DIR/${db}-wal"
            if [ -f "$wal_file" ]; then
                local wal_mtime; wal_mtime=$(stat -c %Y "$wal_file" 2>/dev/null || echo 0)
                local now; now=$(date +%s)
                local age=$((now - wal_mtime))
                if [ "$age" -lt 120 ]; then
                    log "RESTORE: ${db}-wal 在 ${age}s 前被修改，改用安全合并"
                    [ "$db" = "memory.db" ] && merge_session_db "$REPO_DIR/hwcloud-data/$db" "$LOCAL_DIR/$db"
                    continue
                fi
            fi
            # 恢复数据库
            [ -f "$REPO_DIR/hwcloud-data/$db" ] && cp -f "$REPO_DIR/hwcloud-data/$db" "$LOCAL_DIR/$db"
            # 清除本地 WAL/SHM，让 SQLite 重建
            rm -f "$LOCAL_DIR/${db}-wal" "$LOCAL_DIR/${db}-shm" "$LOCAL_DIR/${db}-journal"
        done
    fi

    # 恢复 sessions（-p 保留原始时间戳）
    if [ -d "$REPO_DIR/hwcloud-data/sessions" ]; then
        cp -rfp "$REPO_DIR/hwcloud-data/sessions/"* "$LOCAL_DIR/sessions/" 2>/dev/null
    fi

    # 恢复其他文件
    for f in settings.json SOUL.md user_info.json; do
        [ -f "$REPO_DIR/hwcloud-data/$f" ] && cp -fp "$REPO_DIR/hwcloud-data/$f" "$LOCAL_DIR/$f"
    done

    # 从 .jsonl 补充 messages 表（DevEnv 界面靠 messages 表显示会话标题）
    import_messages_from_jsonl
}

# === 备份 ===
do_backup() {
    # 获取备份锁
    acquire_lock || return 0

    log "BACKUP: 开始"

    # 确保仓库存在
    if [ ! -d "$REPO_DIR/.git" ]; then
        timeout $GIT_TIMEOUT git clone "$REPO_URL" "$REPO_DIR" 2>>"$BACKUP_LOG" >/dev/null
    fi

    cd "$REPO_DIR" || { log "BACKUP: 错误, 仓库目录不可用"; release_lock; return 1; }

    # 拉取最新变更（带超时）
    timeout $GIT_TIMEOUT git pull --rebase origin main 2>>"$BACKUP_LOG" >/dev/null

    # 同步本地数据到仓库
    sync_to_repo

    # 检查是否有变更
    git add -A
    if git diff --cached --quiet 2>/dev/null; then
        log "BACKUP: 无变更, 跳过"
        release_lock
        return 0
    fi

    # 提交并推送（带超时）
    git commit -m "Backup: $(date '+%Y-%m-%d %H:%M:%S')" 2>>"$BACKUP_LOG" >/dev/null
    timeout $GIT_TIMEOUT git push origin main 2>>"$BACKUP_LOG" >/dev/null

    local n; n=$(find "$LOCAL_DIR/sessions" -name "*.jsonl" 2>/dev/null | wc -l)
    log "BACKUP: 完成, 会话数=$n"
    release_lock
}

# === 恢复 ===
do_restore() {
    log "RESTORE: 开始"

    # 克隆或拉取最新
    if [ ! -d "$REPO_DIR/.git" ]; then
        timeout $GIT_TIMEOUT git clone "$REPO_URL" "$REPO_DIR" 2>>"$BACKUP_LOG" >/dev/null
    else
        (cd "$REPO_DIR" && timeout $GIT_TIMEOUT git pull --rebase origin main 2>>"$BACKUP_LOG" >/dev/null)
    fi

    # 从仓库恢复到本地
    sync_from_repo

    local n; n=$(find "$LOCAL_DIR/sessions" -name "*.jsonl" 2>/dev/null | wc -l)
    log "RESTORE: 完成, 会话数=$n"
}

# === 后台定时备份守护进程 ===
start_daemon() {
    # 先杀掉旧进程
    if [ -f "$PID_FILE" ]; then
        local old_pid; old_pid=$(cat "$PID_FILE" 2>/dev/null)
        [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null && kill "$old_pid" 2>/dev/null
    fi

    # 检查是否已在运行
    if [ -f "$PID_FILE" ]; then
        local pid; pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "守护进程已在运行 (PID: $pid)"
            return 0
        fi
    fi

    # 启动后台循环（cd /root 避免 CWD 丢失问题）
    nohup setsid bash -c "cd /root; echo \$\$ > '$PID_FILE'; while true; do '$SCRIPT_PATH' backup; sleep $BACKUP_INTERVAL; done" >/dev/null 2>&1 &
    log "DAEMON: 已启动"
}

# === 自动批准（免确认）===
# 修改 settings.json 把 permission 设为 allow，每次重连自动执行
auto_approve() {
    local settings="$LOCAL_DIR/settings.json"
    [ -f "$settings" ] || return 0

    python3 - "$settings" << 'PYEOF' 2>/dev/null
import json, sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)

changed = False
perm = data.get("permission", {})
if perm.get("*") != "allow":
    perm["*"] = "allow"
    data["permission"] = perm
    changed = True

if changed:
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=4)
    print("CHANGED")
else:
    print("ALREADY_ALLOW")
PYEOF
    local rc=$?
    if [ $rc -eq 0 ]; then
        log "AUTO_APPROVE: permission 已设为 allow"
    fi
    return 0
}

# === 设置 ===
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
# 安全策略：.bashrc 只启动备份守护进程，不自动 restore。
# restore 会覆盖数据库文件，在 AI 进程启动间隙执行会导致数据损坏。
# 容器重建后请手动执行一次：/root/chat-backup.sh restore
if [ -f /root/chat-backup.sh ]; then
    /root/chat-backup.sh daemon 2>/dev/null
    /root/chat-backup.sh auto-approve 2>/dev/null
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
    backup)  do_backup ;;
    restore) do_restore ;;
    setup)        do_setup ;;
    daemon)       start_daemon ;;
    status)       do_status ;;
    auto-approve) auto_approve ;;
    *) echo "用法: $0 {backup|restore|setup|daemon|status|auto-approve}"; exit 1 ;;
esac
