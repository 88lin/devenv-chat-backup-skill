#!/bin/bash
# auto-restore.sh — 容器重启后一键恢复脚本
# 恢复顺序：聊天历史 → GLM Proxy → CF Tunnel → 保活 → 备份守护

RESTORE_LOG="/var/log/auto-restore.log"
LOCAL_DIR="/root/.huawei/hwcloud"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$RESTORE_LOG" 2>/dev/null; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# 1. 恢复聊天历史和配置
restore_chat_history() {
    log "STEP 1: Restoring chat history..."
    if [ -f /root/chat-backup.sh ]; then
        bash /root/chat-backup.sh restore 2>&1 | while read line; do log "  $line"; done
        log "STEP 1: Done"
    else
        log "STEP 1: chat-backup.sh not found, skip"
    fi
}

# 2. 启动 GLM Proxy
start_glm_proxy() {
    log "STEP 2: Starting GLM Proxy..."
    local pid_file="/tmp/glm_proxy.pid"
    
    if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        log "STEP 2: Already running (PID $(cat "$pid_file"))"
        return 0
    fi
    
    if [ -f /root/glm-proxy/glm_proxy.py ] && [ -f /tmp/working_api_key.txt ]; then
        cd /root/glm-proxy
        nohup python3 glm_proxy.py --port 9997 > /tmp/glm_proxy.log 2>&1 &
        echo $! > "$pid_file"
        sleep 2
        if kill -0 "$(cat "$pid_file")" 2>/dev/null; then
            log "STEP 2: Started (PID $(cat "$pid_file"))"
        else
            log "STEP 2: Failed to start"
        fi
    else
        log "STEP 2: Missing files (glm_proxy.py or API key), skip"
    fi
}

# 3. 启动 Cloudflare Tunnel
start_cf_tunnel() {
    log "STEP 3: Starting Cloudflare Tunnel..."
    local pid_file="/tmp/cloudflared.pid"
    
    if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        log "STEP 3: Already running (PID $(cat "$pid_file"))"
        return 0
    fi
    
    if command -v cloudflared >/dev/null 2>&1; then
        nohup cloudflared tunnel --url http://localhost:9997 run glm-proxy > /tmp/cloudflared.log 2>&1 &
        echo $! > "$pid_file"
        sleep 2
        if kill -0 "$(cat "$pid_file")" 2>/dev/null; then
            log "STEP 3: Started (PID $(cat "$pid_file"))"
        else
            log "STEP 3: Failed to start"
        fi
    else
        log "STEP 3: cloudflared not found, skip"
    fi
}

# 4. 启动保活
start_keepalive() {
    log "STEP 4: Starting keepalive..."
    if [ -f /root/keepalive.sh ]; then
        nohup bash /root/keepalive.sh start >> /var/log/keepalive.log 2>&1 &
        log "STEP 4: Started"
    else
        log "STEP 4: keepalive.sh not found, skip"
    fi
}

# 5. 启动备份守护
start_backup_daemon() {
    log "STEP 5: Starting backup daemon..."
    if [ -f /root/chat-backup.sh ]; then
        nohup bash /root/chat-backup.sh daemon >> /var/log/chat-backup.log 2>&1 &
        log "STEP 5: Started"
    else
        log "STEP 5: chat-backup.sh not found, skip"
    fi
}

# 6. 显示状态
show_final_status() {
    log "STEP 6: Final status"
    echo ""
    echo "=== Auto-Restore Complete ==="
    echo "Sessions: $(find "$LOCAL_DIR/sessions" -name "*.jsonl" 2>/dev/null | wc -l)"
    echo "GLM Proxy: $([ -f /tmp/glm_proxy.pid ] && kill -0 "$(cat /tmp/glm_proxy.pid)" 2>/dev/null && echo "running" || echo "stopped")"
    echo "CF Tunnel: $([ -f /tmp/cloudflared.pid ] && kill -0 "$(cat /tmp/cloudflared.pid)" 2>/dev/null && echo "running" || echo "stopped")"
    echo "Keepalive: $([ -f /var/run/keepalive.pid ] && kill -0 "$(cat /var/run/keepalive.pid)" 2>/dev/null && echo "running" || echo "stopped")"
    echo "Backup: $([ -f /var/run/chat-backup.pid ] && kill -0 "$(cat /var/run/chat-backup.pid)" 2>/dev/null && echo "running" || echo "stopped")"
    echo ""
}

# 主流程
main() {
    log "========================================"
    log "Auto-Restore started"
    log "========================================"
    
    restore_chat_history
    start_glm_proxy
    start_cf_tunnel
    start_keepalive
    start_backup_daemon
    show_final_status
    
    log "Auto-Restore finished"
}

case "${1:-run}" in
    run) main ;;
    status)
        echo "=== Auto-Restore Status ==="
        echo "Sessions: $(find "$LOCAL_DIR/sessions" -name "*.jsonl" 2>/dev/null | wc -l)"
        echo "GLM Proxy: $([ -f /tmp/glm_proxy.pid ] && kill -0 "$(cat /tmp/glm_proxy.pid)" 2>/dev/null && echo "running" || echo "stopped")"
        echo "CF Tunnel: $([ -f /tmp/cloudflared.pid ] && kill -0 "$(cat /tmp/cloudflared.pid)" 2>/dev/null && echo "running" || echo "stopped")"
        echo "Keepalive: $([ -f /var/run/keepalive.pid ] && kill -0 "$(cat /var/run/keepalive.pid)" 2>/dev/null && echo "running" || echo "stopped")"
        echo "Backup: $([ -f /var/run/chat-backup.pid ] && kill -0 "$(cat /var/run/chat-backup.pid)" 2>/dev/null && echo "running" || echo "stopped")"
        ;;
    *) echo "Usage: $0 {run|status}" ;;
esac
