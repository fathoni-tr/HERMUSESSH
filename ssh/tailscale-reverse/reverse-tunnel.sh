#!/bin/bash
# reverse-tunnel.sh — Reverse SSH tunnel VM -> laptop user via Tailscale
# Auto-reconnect loop. Kredensial proxy dibaca live dari env (rotate).
# Lokasi: ~/workspace/muse-vps-tailscale/reverse-tunnel.sh (persistent)

RP_HOME="$HOME/workspace/muse-vps-tailscale"
KEY="$RP_HOME/vm-to-laptop-key"
LOG="$RP_HOME/tunnel.log"

# Ambil kredensial proxy dari env live (jangan hardcode — rotate!)
get_proxy_parts() {
    local proxy_url="${HTTPS_PROXY:-$https_proxy}"
    # Format: http://user:pass@host:port
    P_USER=$(echo "$proxy_url" | sed -E 's|http://([^:]+):[^@]+@.*|\1|')
    P_PASS=$(echo "$proxy_url" | sed -E 's|http://[^:]+:([^@]+)@.*|\1|')
    P_HOST=$(echo "$proxy_url" | sed -E 's|http://[^@]+@([^:]+):[0-9]+|\1|')
}

while true; do
    get_proxy_parts
    if [ -z "$P_USER" ] || [ -z "$P_PASS" ]; then
        echo "$(date -Is): proxy env kosong, tunggu 10 detik..." >> "$LOG"
        sleep 10
        continue
    fi
    ssh -i "$KEY" \
        -o "ProxyCommand=nc -X connect -x $P_HOST:3130 -P $P_USER:$P_PASS %h %p" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        -o ConnectTimeout=15 \
        -N -R 2223:localhost:22 \
        Lenovo@100.101.211.43 >> "$LOG" 2>&1
    echo "$(date -Is): tunnel putus (exit $?), reconnect dalam 5 detik..." >> "$LOG"
    sleep 5
done
