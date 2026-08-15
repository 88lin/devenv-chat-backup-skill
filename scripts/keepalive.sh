#!/bin/bash
# keepalive.sh — DevEnv 防断开保活方案
#
# 功能：
#   1. tmux 会话保活 — 断开后进程不死，重连 tmux attach 即可恢复
#   2. 心跳检测 — 记录断开/恢复时间，重连时提醒
#   3. .bashrc 集成 — 新连接自动进入 tmux + 显示断开提醒
#
# 用法：
#   keepalive.sh setup     # 一键设置（配置 tmux + .bashrc + 启动心跳）
#   keepalive.sh attach    # 进入 tmux 会话
#   keepalive.sh status    # 查看保活状态
#   keepalive.sh log       # 查看断开/恢复记录

HEARTBEAT_FILE="/tmp/devenv-heartbeat"
DISCONNECT_LOG="/var/log/devenv-disconnect.log"
TMUX_SESSION="devenv"
HEARTBEAT_INTERVAL=5    # 每5秒写一次心跳

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$DISCONNECT_LOG" 2>/dev/null; }

# === 心跳守护进程 ===
# 持续写心跳时间戳，重连时对比时间差判断是否断开过
start_heartbeat() {
    # 杀掉旧的心跳进程
    pkill -f "devenv-heartbeat-writer" 2>/dev/null

    nohup setsid bash -c '
        while true; do
            date "+%Y-%m-%d %H:%M:%S" > /tmp/devenv-heartbeat
            sleep 5
        done
    ' >/dev/null 2>&1 &

    # 给进程打个标记方便识别
    for pid in $(pgrep -f "devenv-heartbeat"); do
        :
    done
    log "HEARTBEAT: 心跳守护进程已启动"
}

# === 检测断开 ===
# 对比上次心跳时间和当前时间，如果差距大于阈值说明断开过
check_disconnect() {
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        echo "首次运行，无断开记录"
        return
    fi

    local last; last=$(cat "$HEARTBEAT_FILE" 2>/dev/null)
    local now; now=$(date "+%Y-%m-%d %H:%M:%S")

    # 计算时间差（秒）
    local last_ts now_ts diff
    last_ts=$(date -d "$last" +%s 2>/dev/null)
    now_ts=$(date -d "$now" +%s 2>/dev/null)
    diff=$((now_ts - last_ts))

    if [ "$diff" -gt 15 ]; then
        echo ""
        echo "⚠️  检测到断开恢复！"
        echo "   最后心跳: $last"
        echo "   当前时间: $now"
        echo "   断开时长: ${diff} 秒（约 $((diff / 60)) 分钟）"
        echo ""
        log "DISCONNECT: 断开 ${diff} 秒后恢复 (最后心跳: $last)"
    fi
}

# === 配置 tmux ===
setup_tmux_config() {
    cat > /root/.tmux.conf << 'EOF'
# 基本设置
set -g default-shell /bin/bash
set -g history-limit 10000
set -g mouse on

# 256色支持
set -g default-terminal "screen-256color"

# 状态栏 — 显示会话名、窗口、时间
set -g status-style "bg=blue,fg=white"
set -g status-left "[#S] "
set -g status-right "%Y-%m-%d %H:%M "
set -g status-left-length 20

# 窗口标签
set -g window-status-current-style "bg=white,fg=blue"

# 分屏快捷键改为更直观的 | 和 -
bind | split-window -h
bind - split-window -v

# 重新加载配置
bind r source-file ~/.tmux.conf \; display "Config reloaded!"

# 保持会话存活（不要因为客户端断开就退出）
set -g destroy-unattached off
EOF
    echo "✅ tmux 配置已写入 /root/.tmux.conf"
}

# === 配置 .bashrc ===
setup_bashrc() {
    local M="# >>> devenv-keepalive >>>"
    local ME="# <<< devenv-keepalive <<<"

    # 删除旧配置
    grep -q "$M" /root/.bashrc 2>/dev/null && sed -i "/${M}/,/${ME}/d" /root/.bashrc

    cat >> /root/.bashrc << 'BASHRC_EOF'

# >>> devenv-keepalive >>>
# 检测断开恢复
if [ -f /tmp/devenv-heartbeat ]; then
    LAST=$(cat /tmp/devenv-heartbeat 2>/dev/null)
    NOW=$(date "+%Y-%m-%d %H:%M:%S")
    LAST_TS=$(date -d "$LAST" +%s 2>/dev/null)
    NOW_TS=$(date -d "$NOW" +%s 2>/dev/null)
    DIFF=$((NOW_TS - LAST_TS))
    if [ "$DIFF" -gt 15 ] 2>/dev/null; then
        echo ""
        echo "⚠️  检测到断开恢复！断开约 $((DIFF / 60)) 分钟（$DIFF 秒）"
        echo "   最后心跳: $LAST → 现在: $NOW"
        echo ""
    fi
fi

# 更新心跳
date "+%Y-%m-%d %H:%M:%S" > /tmp/devenv-heartbeat

# 提示进入 tmux（不自动 exec，避免替换 shell 进程导致 DevEnv 终端连接断裂）
# 原方案用 exec tmux attach 替换当前 shell，但 DevEnv 的终端管理（devenvd）
# 通过 WebSocket 与 bash shell 通信，shell 被 exec 掉后 DevEnv 认为终端已死 → 连接断开。
# 改为仅提示，用户按需手动 tmux attach。
if command -v tmux >/dev/null 2>&1 && [ -z "$TMUX" ] && [ -n "$PS1" ]; then
    if tmux has-session -t devenv 2>/dev/null; then
        echo "💡 tmux 会话 'devenv' 正在运行，输入 tmux attach -t devenv 可进入"
    fi
fi
# <<< devenv-keepalive <<<
BASHRC_EOF
    echo "✅ .bashrc 已配置自动进入 tmux"
}

# === 一键设置 ===
do_setup() {
    echo "=== DevEnv 防断开保活设置 ==="
    echo ""

    # 1. 检查 tmux
    if ! command -v tmux >/dev/null 2>&1; then
        echo "❌ tmux 未安装，请先执行: dnf install -y tmux"
        return 1
    fi
    echo "1. tmux: ✅ $(tmux -V)"

    # 2. 配置 tmux
    setup_tmux_config

    # 3. 启动心跳
    start_heartbeat
    echo "2. 心跳守护: ✅ 已启动（每${HEARTBEAT_INTERVAL}秒）"

    # 4. 配置 .bashrc
    setup_bashrc

    # 5. 创建 tmux 会话（如果不存在）
    if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        tmux new-session -d -s "$TMUX_SESSION"
        echo "3. tmux 会话: ✅ 已创建 '$TMUX_SESSION'"
    else
        echo "3. tmux 会话: ✅ 已存在 '$TMUX_SESSION'"
    fi

    echo ""
    echo "=== 设置完成 ==="
    echo ""
    echo "📋 使用方法："
    echo "   • 进入会话:  tmux attach -t devenv  （或直接开新终端自动进入）"
    echo "   • 临时退出:  Ctrl+B 然后按 D （会话保持运行）"
    echo "   • 查看状态:  keepalive.sh status"
    echo "   • 查看断开记录: keepalive.sh log"
    echo ""
    echo "💡 原理：断开后 tmux 会话不死，重连自动恢复，正在运行的命令不会中断"
}

# === 状态 ===
do_status() {
    echo "=== 防断开保活状态 ==="

    # tmux
    if command -v tmux >/dev/null 2>&1; then
        echo "tmux: ✅ $(tmux -V)"
        if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
            local n; n=$(tmux list-windows -t "$TMUX_SESSION" 2>/dev/null | wc -l)
            echo "会话 '$TMUX_SESSION': ✅ 运行中 ($n 个窗口)"
            tmux list-windows -t "$TMUX_SESSION" 2>/dev/null | while read line; do
                echo "  └─ $line"
            done
        else
            echo "会话 '$TMUX_SESSION': ❌ 未创建"
        fi
    else
        echo "tmux: ❌ 未安装"
    fi

    # 心跳
    if [ -f "$HEARTBEAT_FILE" ]; then
        local last; last=$(cat "$HEARTBEAT_FILE")
        local now; now=$(date "+%Y-%m-%d %H:%M:%S")
        local diff; diff=$(( $(date -d "$now" +%s) - $(date -d "$last" +%s) ))
        echo "心跳: ✅ 最后心跳 $last (${diff}秒前)"
    else
        echo "心跳: ❌ 未启动"
    fi

    # .bashrc
    grep -q "devenv-keepalive" /root/.bashrc 2>/dev/null && echo ".bashrc: ✅" || echo ".bashrc: ❌"

    # 断开记录
    echo ""
    echo "最近断开记录:"
    tail -3 "$DISCONNECT_LOG" 2>/dev/null || echo "  (无记录)"
}

# === 查看日志 ===
do_log() {
    echo "=== 断开/恢复记录 ==="
    cat "$DISCONNECT_LOG" 2>/dev/null || echo "(无记录)"
}

# === 主逻辑 ===
case "${1:-}" in
    setup)   do_setup ;;
    status)  do_status ;;
    log)     do_log ;;
    attach)  tmux attach -t "$TMUX_SESSION" 2>/dev/null || tmux new -s "$TMUX_SESSION" ;;
    *) echo "用法: $0 {setup|status|log|attach}"; exit 1 ;;
esac
