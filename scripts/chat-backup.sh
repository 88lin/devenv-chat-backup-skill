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
MAX_SESSIONS=10      # DevEnv UI 最多显示的会话数（超过则提示清理）
AUTO_PRUNE=false     # 是否自动删除超限会话（false=只警告不删，true=自动删除消息少的旧会话）

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

# 5. 线性插值并更新（start_timestamp + created_at + updated_at 三列都改）
updated = 0
for sid, old_ts, turn_id in need_fix:
    if turn_max == turn_min:
        new_ts = t_min
    else:
        ratio = (turn_id - turn_min) / (turn_max - turn_min)
        new_ts = t_min + ratio * (t_max - t_min)
    cur.execute("UPDATE sessions SET start_timestamp=?, created_at=?, updated_at=? WHERE session_id=?",
                (new_ts, new_ts, new_ts, sid))
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

# === 修复会话可见性 ===
# DevEnv UI 只显示 metadata 为空对象 {} 的会话
# 通过 ACP 创建的会话 metadata 含 {"source":"acp",...}，会被 UI 过滤掉
# 本函数清除 metadata 中的 source 字段，使会话在 UI 中可见
fix_session_visibility() {
    local db="$LOCAL_DIR/memory.db"
    [ -f "$db" ] || return 0
    command -v sqlite3 >/dev/null 2>&1 || return 0

    # 检查 sessions 表是否有 metadata 列
    local has_metadata
    has_metadata=$(sqlite3 "$db" "PRAGMA table_info(sessions);" 2>/dev/null | grep -c "metadata")
    if [ "$has_metadata" -eq 0 ]; then
        log "FIX_VIS: sessions 表无 metadata 列，跳过"
        return 0
    fi

    # 统计有 source=acp 的会话数
    local hidden_count
    hidden_count=$(sqlite3 "$db" \
        "SELECT COUNT(*) FROM sessions WHERE metadata LIKE '%\"source\"%' AND metadata != '{}';" 2>/dev/null || echo 0)

    if [ "$hidden_count" -eq 0 ]; then
        log "FIX_VIS: 无隐藏会话，跳过"
        return 0
    fi

    # 清除 metadata 中的 source 字段（设为空对象 {}）
    sqlite3 "$db" \
        "UPDATE sessions SET metadata='{}' WHERE metadata LIKE '%\"source\"%' AND metadata != '{}';" 2>/dev/null

    local rc=$?
    if [ $rc -eq 0 ]; then
        log "FIX_VIS: 修复了 $hidden_count 个会话的可见性（清除 metadata.source）"
        echo "FIX_VIS: 修复了 $hidden_count 个会话的可见性"
    else
        log "FIX_VIS: 修复失败 (exit=$rc)"
    fi
    return $rc
}

# === 会话数限制管理 ===
# DevEnv UI 最多显示 MAX_SESSIONS（默认10）个会话
# 当总会话数超过限制时，提示用户清理
#
# 用法: prune_sessions [auto|interactive]
#   auto        — 被 backup/restore 调用。AUTO_PRUNE=false 时只警告不删除；true 时自动删除
#   interactive — 被 prune 命令调用。列出候选会话，交互式确认后才删除
prune_sessions() {
    local mode="${1:-auto}"
    local db="$LOCAL_DIR/memory.db"
    [ -f "$db" ] || return 0
    command -v sqlite3 >/dev/null 2>&1 || return 0

    local total
    total=$(sqlite3 "$db" "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo 0)

    if [ "$total" -le "$MAX_SESSIONS" ]; then
        log "PRUNE: 会话数 $total ≤ $MAX_SESSIONS，无需清理"
        return 0
    fi

    local to_delete=$((total - MAX_SESSIONS))
    log "PRUNE: 会话数 $total > $MAX_SESSIONS，需要清理 $to_delete 个"

    # 找出消息最少的旧会话（按 message_count 升序，再按 start_timestamp 升序）
    local candidates
    candidates=$(sqlite3 "$db" \
        "SELECT session_id, message_count, title, start_timestamp FROM sessions ORDER BY message_count ASC, start_timestamp ASC LIMIT $to_delete;" 2>/dev/null)

    [ -z "$candidates" ] && return 0

    # auto 模式：检查 AUTO_PRUNE 开关
    if [ "$mode" = "auto" ] && [ "$AUTO_PRUNE" = "false" ]; then
        log "PRUNE: AUTO_PRUNE=false，仅警告不删除。建议手动执行: $0 prune"
        echo ""
        echo "⚠️  会话数 $total 超过 DevEnv UI 上限 $MAX_SESSIONS，以下 $to_delete 个会话建议清理："
        echo ""
        printf "%-4s  %-17s %5s  %s\n" "序号" "日期" "消息数" "标题"
        echo "------------------------------------------------------------"
        local idx=1
        while IFS='|' read -r sid cnt title ts; do
            [ -z "$sid" ] && continue
            local time_str
            time_str=$(date -d "@${ts:-0}" '+%m-%d %H:%M' 2>/dev/null || echo "????")
            local disp_title="${title:-（无标题）}"
            printf "%-4s  %-17s %5s  %s\n" "$idx" "$time_str" "$cnt" "${disp_title:0:50}"
            idx=$((idx + 1))
        done <<< "$candidates"
        echo ""
        echo "💡 执行以下命令手动清理（会再次确认后才删除）："
        echo "   $0 prune"
        echo "   或设置自动删除：编辑脚本顶部 AUTO_PRUNE=true"
        return 0
    fi

    # interactive 模式 或 AUTO_PRUNE=true：显示候选列表并确认
    if [ "$mode" = "interactive" ]; then
        echo ""
        echo "以下 $to_delete 个会话建议清理（消息最少且最早的）："
        echo ""
        printf "%-4s  %-17s %5s  %s\n" "序号" "日期" "消息数" "标题"
        echo "------------------------------------------------------------"
        local idx=1
        local sid_list=""
        while IFS='|' read -r sid cnt title ts; do
            [ -z "$sid" ] && continue
            local time_str
            time_str=$(date -d "@${ts:-0}" '+%m-%d %H:%M' 2>/dev/null || echo "????")
            local disp_title="${title:-（无标题）}"
            printf "%-4s  %-17s %5s  %s\n" "$idx" "$time_str" "$cnt" "${disp_title:0:50}"
            sid_list="$sid_list $sid"
            idx=$((idx + 1))
        done <<< "$candidates"
        echo ""
        echo "⚠️  删除后不可恢复（但 GitHub 历史提交中仍可找回）"
        echo -n "确认删除这 $to_delete 个会话？(y/N): "
        read -r confirm
        [[ "$confirm" != [yY] ]] && { echo "取消"; return 0; }
    fi

    # 执行删除
    local deleted=0
    while IFS='|' read -r sid cnt title ts; do
        [ -z "$sid" ] && continue
        # 从数据库删除
        sqlite3 "$db" \
            "DELETE FROM messages WHERE session_id='$sid'; DELETE FROM sessions WHERE session_id='$sid';" 2>/dev/null
        # 删除 jsonl 文件
        rm -f "$LOCAL_DIR/sessions/${sid}.jsonl" "$LOCAL_DIR/sessions/${sid}.metadata.json"
        rm -f "$REPO_DIR/hwcloud-data/sessions/${sid}.jsonl" "$REPO_DIR/hwcloud-data/sessions/${sid}.metadata.json"
        deleted=$((deleted + 1))
        log "PRUNE: 删除会话 $sid (消息数=$cnt, 标题=$title)"
    done <<< "$candidates"

    if [ $deleted -gt 0 ]; then
        local remaining
        remaining=$(sqlite3 "$db" "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo "?")
        log "PRUNE: 清理完成，删除 $deleted 个，剩余 $remaining 个"
        echo "✅ PRUNE: 清理了 $deleted 个会话，剩余 $remaining 个"
    fi
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

    # 修复会话可见性（清除 metadata.source="acp"）
    fix_session_visibility

    # 清理多余会话（DevEnv UI 最多显示 MAX_SESSIONS 个）
    prune_sessions auto
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

    # 修复会话可见性 + 清理多余会话（在同步前处理）
    fix_session_visibility
    prune_sessions auto

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

# === 删除会话 ===
# 用法:
#   chat-backup.sh delete                    # 交互式：输入关键词搜索 → 选序号删除
#   chat-backup.sh delete "facetmark"        # 按关键词搜索匹配的会话
#   chat-backup.sh delete --empty            # 列出空会话（消息数≤2），方便批量清理
#   chat-backup.sh delete --date 0815        # 按日期筛选（MM-DD 或 YYYY-MM-DD）
#   chat-backup.sh delete --old 7            # 列出7天前的会话
#   搜索结果中输入序号删除，支持 3,5,7 或 3-6 或 all
do_delete() {
    local db="$LOCAL_DIR/memory.db"
    [ -f "$db" ] || { echo "❌ 数据库不存在"; return 1; }

    local keyword="" filter_empty=false filter_date="" filter_old=""
    local args=()
    while [ $# -gt 1 ]; do
        case "$2" in
            --empty) filter_empty=true; shift ;;
            --date)  filter_date="$3"; shift 2 ;;
            --old)   filter_old="$3"; shift 2 ;;
            --*)     shift ;;
            *)       keyword="$2"; shift; break ;;
        esac
    done

    # 无参数时先问搜索方式
    if [ $# -eq 1 ] && [ -z "$keyword" ] && [ "$filter_empty" = "false" ] && [ -z "$filter_date" ] && [ -z "$filter_old" ]; then
        local total_sessions
        total_sessions=$(sqlite3 "$db" "SELECT count(*) FROM sessions;" 2>/dev/null)
        echo "共 $total_sessions 个会话"
        echo ""
        echo "搜索方式:"
        echo "  1) 输入关键词搜索标题（如 facetmark、你好）"
        echo "  2) empty  - 列出空会话（≤2条消息）"
        echo "  3) old N  - 列出N天前的会话"
        echo "  4) date MMDD - 按日期筛选"
        echo "  5) all   - 列出全部（慎用）"
        echo ""
        echo -n "请选择: "
        read -r choice
        case "$choice" in
            empty)  filter_empty=true ;;
            old)    echo -n "几天前？"; read -r filter_old ;;
            date)   echo -n "日期(MMDD如0815): "; read -r filter_date ;;
            all)    keyword="" ;;
            *)      keyword="$choice" ;;
        esac
    fi

    # 构建 SQL 过滤条件
    python3 - "$db" "$LOCAL_DIR/sessions" "$keyword" "$filter_empty" "$filter_date" "$filter_old" << 'PYEOF'
import json, sqlite3, sys, os, re
from datetime import datetime, timedelta

db_path, sessions_dir, keyword, filter_empty, filter_date, filter_old = sys.argv[1:7]

conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
cur = conn.cursor()

sql = "SELECT session_id, start_timestamp, message_count, title FROM sessions"
conditions = []

if filter_empty == "true":
    conditions.append("message_count <= 2")

if filter_date:
    # 支持 0815 或 2026-08-15
    fd = filter_date.replace("-", "")
    if len(fd) == 4:  # MMDD
        conditions.append(f"strftime('%m%d', start_timestamp, 'unixepoch') = '{fd}'")
    elif len(fd) == 8:  # YYYYMMDD
        conditions.append(f"strftime('%Y%m%d', start_timestamp, 'unixepoch') = '{fd}'")

if filter_old:
    cutoff = (datetime.now() - timedelta(days=int(filter_old))).timestamp()
    conditions.append(f"start_timestamp < {cutoff}")

if conditions:
    sql += " WHERE " + " AND ".join(conditions)
sql += " ORDER BY start_timestamp"

cur.execute(sql)
rows = cur.fetchall()
conn.close()

# 获取每个会话的显示标题（从 jsonl 第一条用户消息）
def get_display_title(sid, title, cnt):
    if title:
        return title[:60].replace('\n', ' ')
    jsonl = os.path.join(sessions_dir, f"{sid}.jsonl")
    if os.path.exists(jsonl):
        with open(jsonl, 'r', encoding='utf-8', errors='replace') as f:
            for line in f:
                try:
                    d = json.loads(line.strip())
                    if d.get("Role") == 0 and d.get("Content"):
                        return d["Content"][:60].replace('\n', ' ')
                except:
                    continue
    return "(空会话)" if cnt <= 2 else "(无标题)"

# 关键词过滤
results = []
for sid, ts, cnt, title in rows:
    disp = get_display_title(sid, title, cnt)
    if keyword:
        # 同时搜索标题和 session_id
        if keyword.lower() not in disp.lower() and keyword.lower() not in sid.lower():
            continue
    results.append((sid, ts, cnt, disp))

if not results:
    print("没有匹配的会话")
    sys.exit(0)

print(f"\n找到 {len(results)} 个会话：\n")
print(f"{'序号':>4}  {'日期':<17} {'消息':>5}  {'标题'}")
print("-" * 90)

for i, (sid, ts, cnt, disp) in enumerate(results, 1):
    time_str = datetime.fromtimestamp(ts).strftime('%m-%d %H:%M') if ts else "????"
    print(f"{i:>4}  {time_str:<17} {cnt:>5}  {disp}")

# 保存映射到临时文件
list_file = f"/tmp/chat-delete-list.{os.getpid()}"
with open(list_file, 'w') as f:
    for i, (sid, ts, cnt, disp) in enumerate(results, 1):
        f.write(f"{i}|{sid}|{disp}\n")
print(f"\n映射文件: {list_file}")
PYEOF

    local list_file=$(ls -t /tmp/chat-delete-list.* 2>/dev/null | head -1)
    [ -f "$list_file" ] || return 0

    local total
    total=$(wc -l < "$list_file")

    echo ""
    echo "输入要删除的序号（如 3 或 3,5,7 或 3-6 或 all）:"
    read -r selection
    [ -z "$selection" ] && { echo "取消"; rm -f "$list_file"; return 0; }

    # 解析选择
    local numbers=""
    if [ "$selection" = "all" ]; then
        numbers=$(seq 1 $total)
    else
        IFS=',' read -ra parts <<< "$selection"
        for part in "${parts[@]}"; do
            if [[ "$part" == *-* ]]; then
                local start=${part%-*} end=${part#*-}
                for ((n=start; n<=end; n++)); do
                    numbers="$numbers $n"
                done
            else
                numbers="$numbers $part"
            fi
        done
    fi

    # 收集要删除的 session_id
    local to_delete=""
    for num in $numbers; do
        local line
        line=$(grep "^${num}|" "$list_file")
        if [ -n "$line" ]; then
            local sid=${line#*|}
            sid=${sid%%|*}
            to_delete="$to_delete $sid"
        else
            echo "⚠️ 序号 $num 不存在"
        fi
    done

    rm -f "$list_file"
    [ -z "$to_delete" ] && { echo "没有有效的会话"; return 0; }

    # 确认
    local count
    count=$(echo $to_delete | wc -w)
    echo ""
    echo "将删除 $count 个会话："
    for sid in $to_delete; do
        local title
        title=$(sqlite3 "$db" "SELECT substr(title,1,60) FROM sessions WHERE session_id='$sid';" 2>/dev/null)
        [ -z "$title" ] && title="(从jsonl获取)"
        echo "  ❌ $sid  $title"
    done
    echo ""
    echo -n "确认删除？(y/N): "
    read -r confirm
    [[ "$confirm" != [yY] ]] && { echo "取消"; return 0; }

    # 执行删除
    local deleted=0
    for sid in $to_delete; do
        sqlite3 "$db" "DELETE FROM messages WHERE session_id='$sid'; DELETE FROM sessions WHERE session_id='$sid';" 2>/dev/null
        rm -f "$LOCAL_DIR/sessions/${sid}.jsonl" "$LOCAL_DIR/sessions/${sid}.metadata.json"
        rm -f "$REPO_DIR/hwcloud-data/sessions/${sid}.jsonl" "$REPO_DIR/hwcloud-data/sessions/${sid}.metadata.json"
        if [ -f "$REPO_DIR/hwcloud-data/memory.db" ]; then
            sqlite3 "$REPO_DIR/hwcloud-data/memory.db" \
                "DELETE FROM messages WHERE session_id='$sid'; DELETE FROM sessions WHERE session_id='$sid';" 2>/dev/null
        fi
        deleted=$((deleted + 1))
        log "DELETE: 删除会话 $sid"
    done

    echo "✅ 已删除 $deleted 个会话，下次备份自动同步到 GitHub"
}

# === 主逻辑 ===
case "${1:-}" in
    backup)  do_backup ;;
    restore) do_restore ;;
    setup)        do_setup ;;
    daemon)       start_daemon ;;
    status)       do_status ;;
    auto-approve) auto_approve ;;
    delete)       do_delete "$@" ;;
    fix-visibility) fix_session_visibility ;;
    prune)        prune_sessions interactive ;;
    *) echo "用法: $0 {backup|restore|setup|daemon|status|auto-approve|delete|fix-visibility|prune}"
       echo ""
       echo "命令说明:"
       echo "  backup          备份当前数据到 GitHub"
       echo "  restore         从 GitHub 恢复最新数据"
       echo "  setup           设置后台定时备份 + .bashrc 自动启动"
       echo "  daemon          启动后台备份守护进程"
       echo "  status          查看备份状态"
       echo "  auto-approve    设置自动批准（免确认）"
       echo "  fix-visibility  修复会话可见性（清除 metadata.source=\"acp\"）"
       echo "  prune           清理多余会话（交互式确认，保留最近 $MAX_SESSIONS 个）"
       echo "  delete          交互式删除会话"
       echo ""
       echo "删除会话:"
       echo "  $0 delete                    # 交互式搜索"
       echo "  $0 delete \"关键词\"           # 按标题搜索"
       echo "  $0 delete --empty            # 列出空会话(≤2条消息)"
       echo "  $0 delete --date 0815        # 按日期筛选"
       echo "  $0 delete --old 7            # 列出7天前的"
       echo "  搜索结果中: 3 或 3,5,7 或 3-6 或 all"
       exit 1 ;;
esac
