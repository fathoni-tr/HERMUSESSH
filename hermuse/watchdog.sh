#!/bin/bash
# Watchdog: pastikan 9Router, tunnel client, dan Telegram gateway tetap jalan.
# Dijalankan via cron tiap 5 menit:
#   */5 * * * * /path/ke/Hermuse/watchdog.sh
#
# (Untuk cron: simpan URL tunnel di file .tunnel-url (chmod 600) di folder ini,
#  karena cron tidak mewarisi environment variable interaktif.)
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESTARTED=""

# 1. 9Router (127.0.0.1:20128) — cek endpoint dashboard merespons
if ! curl -s -m 8 -o /dev/null http://127.0.0.1:20128/dashboard; then
  bash "$D/restart-9router.sh" > /dev/null 2>&1
  RESTARTED="$RESTARTED 9router"
fi

# 2. Tunnel client (proses node tunnel-client.mjs)
# Pola "[.]" = exact match, agar tidak ikut cocok dengan tunnel client lain
# (mis. tunnel-client-hermesum.mjs) di setup multi-tunnel.
if ! pgrep -f "tunnel-client[.]mjs" > /dev/null 2>&1; then
  bash "$D/restart-tunnel.sh" > /dev/null 2>&1
  RESTARTED="$RESTARTED tunnel"
fi

# 3. Telegram gateway (hermes gateway run)
if ! ps aux | grep "[g]ateway.*run" > /dev/null 2>&1; then
  bash "$D/start-gateway.sh" > /dev/null 2>&1
  RESTARTED="$RESTARTED gateway"
fi

if [ -n "$RESTARTED" ]; then
  echo "[$(date -u '+%F %H:%M:%S')] watchdog restarted:$RESTARTED" >> "$D/watchdog.log"
fi
