#!/bin/bash
# vm-boot.sh — master boot script for Muse VM
# Reinstalls (if wiped) and restarts: sshd, Tailscale, 9Router, Hermes gateway, 9remote
# Stored in ~/workspace (persistent across VM replacements)
# Run: bash ~/workspace/bin/vm-boot.sh
set -u
LOG="$HOME/workspace/vm-boot.log"
exec >>"$LOG" 2>&1
echo "=== vm-boot started: $(date -Is) ==="

# Proxy for all outbound HTTPS
export ALL_PROXY="${ALL_PROXY:-http://hatch-egress-proxy:3128}"
export HTTPS_PROXY="$ALL_PROXY"
export https_proxy="$ALL_PROXY"
export HTTP_PROXY="$ALL_PROXY"
export http_proxy="$ALL_PROXY"
export NO_PROXY="localhost,127.0.0.1,::1"
export no_proxy="$NO_PROXY"

BIN_DIR="$HOME/workspace/bin"
mkdir -p "$BIN_DIR"

# ---------------------------------------------------------- 1. sshd
if [ ! -x /usr/sbin/sshd ]; then
    echo "[sshd] reinstalling..."
    cd /tmp
    curl -sL -o os.deb "https://mirrors.edge.kernel.org/ubuntu/pool/main/o/openssh/openssh-server_9.6p1-3ubuntu13.19_amd64.deb" && \
    curl -sL -o sftp.deb "https://mirrors.edge.kernel.org/ubuntu/pool/main/o/openssh/openssh-sftp-server_9.6p1-3ubuntu13.19_amd64.deb" && \
    dpkg -i sftp.deb os.deb 2>&1 | tail -1
    mkdir -p /run/sshd && chmod 755 /run/sshd
    ssh-keygen -A 2>/dev/null
fi
if [ -x /usr/sbin/sshd ]; then
    cat > /etc/ssh/sshd_config_bridge <<'EOF'
Port 22
Port 2200
ListenAddress 0.0.0.0
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM no
X11Forwarding no
PrintMotd no
PidFile /run/sshd-bridge.pid
AuthorizedKeysFile .ssh/authorized_keys
EOF
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    cp ~/workspace/ssh-bridge/user-ssh-key.pub /root/.ssh/authorized_keys 2>/dev/null
    chmod 600 /root/.ssh/authorized_keys 2>/dev/null
    if [ -f ~/workspace/ssh-bridge/.ssh-cred ]; then
        SSHPASS=$(cut -d: -f2 ~/workspace/ssh-bridge/.ssh-cred)
        echo "root:$SSHPASS" | chpasswd 2>/dev/null
    fi
    pgrep -x sshd >/dev/null || /usr/sbin/sshd -f /etc/ssh/sshd_config_bridge
    pgrep -x sshd >/dev/null && echo "[sshd] UP" || echo "[sshd] FAILED"
fi

# ---------------------------------------------------------- 2. Tailscale
TS_TGZ="$BIN_DIR/tailscale_1.86.2_amd64.tgz"
if [ ! -x /usr/local/bin/tailscaled ]; then
    echo "[tailscale] reinstalling..."
    if [ ! -f "$TS_TGZ" ]; then
        curl -sL "https://pkgs.tailscale.com/stable/tailscale_1.86.2_amd64.tgz" -o "$TS_TGZ"
    fi
    cd /tmp && tar xzf "$TS_TGZ" && \
    cp tailscale_1.86.2_amd64/tailscale tailscale_1.86.2_amd64/tailscaled /usr/local/bin/
fi
if [ -x /usr/local/bin/tailscaled ]; then
    mkdir -p /var/lib/tailscale /run/tailscale
    # Restore persistent Tailscale identity (survives VM replacement)
    if [ -f "$BIN_DIR/tailscaled.state" ] && [ ! -f /var/lib/tailscale/tailscaled.state ]; then
        cp "$BIN_DIR/tailscaled.state" /var/lib/tailscale/tailscaled.state
        echo "[tailscale] identity restored from backup"
    fi
    pgrep -x tailscaled >/dev/null || \
        nohup /usr/local/bin/tailscaled --state=/var/lib/tailscale/tailscaled.state \
            --socket=/run/tailscale/tailscaled.sock --port=41641 >/tmp/tailscaled.log 2>&1 &
    sleep 3
    # 'up' with auth key (auto-login, no URL needed) — timeout so boot doesn't hang
    AUTHKEY_FILE="$BIN_DIR/.tailscale-authkey"
    if [ -f "$AUTHKEY_FILE" ]; then
        echo "[tailscale] using auth key from $AUTHKEY_FILE"
        timeout 60 /usr/local/bin/tailscale --socket=/run/tailscale/tailscaled.sock up \
            --auth-key=$(cat "$AUTHKEY_FILE") 2>&1 | head -3
    else
        echo "[tailscale] WARNING: auth key file MISSING ($AUTHKEY_FILE) - falling back to interactive login"
        timeout 50 /usr/local/bin/tailscale --socket=/run/tailscale/tailscaled.sock up 2>&1 | head -5
    fi
    # Auth-key login can finish in the daemon shortly after the CLI times out;
    # give it a moment before reporting state (avoids false NeedsLogin in log).
    sleep 5
    /usr/local/bin/tailscale --socket=/run/tailscale/tailscaled.sock ip 2>&1 | head -1
    # Backup identity for next boot
    cp /var/lib/tailscale/tailscaled.state "$BIN_DIR/tailscaled.state" 2>/dev/null
    chmod 600 "$BIN_DIR/tailscaled.state" 2>/dev/null
fi

# ---------------------------------------------------------- 3. 9Router
if ! curl -fsS --max-time 4 http://127.0.0.1:20128/api/health >/dev/null 2>&1; then
    echo "[9router] restarting..."
    bash ~/workspace/Hermuse/restart-9router.sh 2>&1 | tail -2
    sleep 5
fi
curl -fsS --max-time 4 http://127.0.0.1:20128/api/health >/dev/null 2>&1 \
    && echo "[9router] UP" || echo "[9router] FAILED"

# ---------------------------------------------------------- 4. Hermes gateway (Telegram)
if ! pgrep -f "gateway run" >/dev/null; then
    echo "[gateway] starting..."
    bash ~/workspace/Hermuse/start-gateway.sh 2>&1 | tail -2
    sleep 8
fi
pgrep -f "gateway run" >/dev/null && echo "[gateway] UP" || echo "[gateway] FAILED"

# ---------------------------------------------------------- 5. 9remote
if [ ! -x /usr/bin/9remote ]; then
    echo "[9remote] reinstalling via npm 11..."
    node ~/.npm11/package/bin/npm-cli.js install -g 9remote 2>&1 | tail -1
fi
if [ -x /usr/bin/9remote ]; then
    pgrep -f "9remote.*start" >/dev/null || \
        nohup 9remote start > ~/workspace/9remote.log 2>&1 &
    sleep 5
    pgrep -f "9remote.*start" >/dev/null && echo "[9remote] UP" || echo "[9remote] FAILED"
fi

# ---------------------------------------------------------- 6. Reverse SSH tunnel (Tailscale -> laptop user)
# Tunnel: laptop user port 2223 -> VM port 22 (sshd)
# Script persistent di ~/workspace/muse-vps-tailscale/reverse-tunnel.sh
RT_DIR="$HOME/workspace/muse-vps-tailscale"
if [ -x "$RT_DIR/reverse-tunnel.sh" ]; then
    # Restore user public key ke authorized_keys (terhapus saat VM replace)
    if [ -f "$RT_DIR/user-authorized-key.pub" ]; then
        mkdir -p /root/.ssh && chmod 700 /root/.ssh
        grep -q "lenovo@o23" /root/.ssh/authorized_keys 2>/dev/null || \
            cat "$RT_DIR/user-authorized-key.pub" >> /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys 2>/dev/null
    fi
    # Start tunnel supervisor kalau belum jalan
    if ! pgrep -f "muse-vps-tailscale/reverse" >/dev/null; then
        echo "[reverse-tunnel] starting..."
        nohup "$RT_DIR/reverse-tunnel.sh" > /dev/null 2>&1 &
        sleep 8
    fi
    pgrep -f "muse-vps-tailscale/reverse" >/dev/null && echo "[reverse-tunnel] UP" || echo "[reverse-tunnel] FAILED"
fi

echo "=== vm-boot finished: $(date -Is) ==="
