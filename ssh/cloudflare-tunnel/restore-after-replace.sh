#!/bin/bash
# restore-after-replace.sh — pulihkan tunnel + sshd setelah VM replacement,
# atau restart service yang mati. IDEMPOTEN: aman dijalankan kapan saja.
# Output: "RESTORED" jika ada yang diperbaiki, "OK" jika semua sehat.
set -u
RP=/home/hatch/workspace/rp
LOG=$RP/restore.log
LOCK=$RP/.restore.lock

exec 9>"$LOCK"
flock -n 9 || { echo "OK"; exit 0; }  # restore lain sedang jalan

log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }
RESTORED=0

# 1. Refresh proxy env (password proxy bisa rotate tiap sesi/VM)
python3 - "$RP" <<'PYEOF'
import os, shlex, sys
rp = sys.argv[1]
px = os.environ.get('https_proxy') or os.environ.get('HTTPS_PROXY') or os.environ.get('http_proxy')
if px:
    with open(rp + '/.proxy-env', 'w') as f:
        for v in ('http_proxy', 'https_proxy', 'HTTP_PROXY', 'HTTPS_PROXY'):
            f.write("%s=%s\n" % (v, shlex.quote(os.environ.get(v) or px)))
    os.chmod(rp + '/.proxy-env', 0o600)
PYEOF

# 2. cloudflared harus ada
if [ ! -x /usr/bin/cloudflared ] && [ ! -x /usr/local/bin/cloudflared ]; then
    log "cloudflared hilang, coba download via proxy"
    if [ -f $RP/.proxy-env ]; then set -a; . $RP/.proxy-env; set +a; fi
    mkdir -p $RP/bin
    if curl -fSL --retry 2 --max-time 300 -o $RP/bin/cloudflared \
        https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
        && chmod +x $RP/bin/cloudflared; then
        cp $RP/bin/cloudflared /usr/bin/cloudflared
        ln -sf /usr/bin/cloudflared /usr/local/bin/cloudflared
        log "cloudflared di-restore"
        RESTORED=1
    else
        log "FATAL: cloudflared tidak bisa di-restore"
        echo "FAILED"; exit 1
    fi
fi

# 3. Unit rp-tunnel.service harus terinstall
if [ ! -f /etc/systemd/system/rp-tunnel.service ]; then
    cp $RP/rp-tunnel.service /etc/systemd/system/rp-tunnel.service
    systemctl daemon-reload
    systemctl enable rp-tunnel.service
    log "rp-tunnel.service di-reinstall"
    RESTORED=1
fi

# 4. openssh-server harus ada
if ! command -v sshd >/dev/null 2>&1; then
    log "sshd hilang, install ulang via apt"
    mkdir -p $RP/apt-empty.d
    cat > $RP/apt-minimal.sources <<'EOF'
Types: deb
URIs: http://azure.archive.ubuntu.com/ubuntu
Suites: noble noble-updates noble-security
Components: main
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    OPTS="-o Dir::Etc::sourcelist=$RP/apt-minimal.sources -o Dir::Etc::sourceparts=$RP/apt-empty.d"
    if [ -f $RP/.proxy-env ]; then set -a; . $RP/.proxy-env; set +a; fi
    if apt-get $OPTS update >/dev/null 2>&1 && \
       DEBIAN_FRONTEND=noninteractive apt-get $OPTS install -y openssh-server >/dev/null 2>&1; then
        [ -f $RP/sshd_config ] && cp $RP/sshd_config /etc/ssh/sshd_config
        # kembalikan password root yang SAMA (dari hash backup)
        if [ -f $RP/.root_shadow ] && [ -s $RP/.root_shadow ]; then
            usermod -p "$(cat $RP/.root_shadow)" root && log "password root di-restore (tetap sama)"
        fi
        mkdir -p /run/sshd
        systemctl enable --now ssh
        log "openssh-server di-reinstall"
        RESTORED=1
    else
        log "FATAL: apt install openssh-server gagal"
        echo "FAILED"; exit 1
    fi
fi

# 5. Pastikan service jalan
for svc in ssh rp-tunnel.service; do
    if ! systemctl is-active --quiet $svc 2>/dev/null; then
        systemctl restart $svc 2>/dev/null || systemctl start $svc 2>/dev/null || true
        sleep 3
        if systemctl is-active --quiet $svc 2>/dev/null; then
            log "$svc di-start ulang"
            RESTORED=1
        else
            log "FATAL: $svc tidak bisa jalan"
        fi
    fi
done

# 6. Tunggu tunnel register (maks 90 detik)
for i in $(seq 1 9); do
    if ss -tnp 2>/dev/null | grep -q "ESTAB.*cloudflared"; then
        log "tunnel OK (edge connected)"
        break
    fi
    sleep 10
done

if [ $RESTORED -eq 1 ]; then
    log "restore selesai"
    echo "RESTORED"
else
    echo "OK"
fi
