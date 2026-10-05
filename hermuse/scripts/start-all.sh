#!/bin/bash
# start-all.sh — nyalakan semua komponen Hermuse yang mati. IDEMPOTEN:
# yang sudah jalan tidak disentuh.
#
# Cakupan (HANYA komponen Hermuse — bukan project lain):
#   1. 9Router            (127.0.0.1:20128)
#   2. Tunnel client      (node tunnel-client.mjs -> Pages tunnel)
#   3. Telegram gateway   (hermes gateway run)
#
# Cara pakai manual:
#   bash /path/ke/Hermuse/scripts/start-all.sh
#
# Auto-start setelah reboot (VPS normal) — contoh cron:
#   @reboot sleep 30 && /path/ke/Hermuse/scripts/start-all.sh >> /path/ke/Hermuse/boot.log 2>&1
# Lihat section "Auto-start" di README.md untuk opsi systemd.
#
# Catatan: butuh file .tunnel-url (chmod 600) berisi URL Pages project,
# karena @reboot/cron tidak mewarisi environment variable interaktif.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STARTED=""

# 1. 9Router
if ! curl -s -m 8 -o /dev/null http://127.0.0.1:20128/dashboard; then
  bash "$ROOT/restart-9router.sh" > /dev/null 2>&1
  STARTED="$STARTED 9router"
fi

# 2. Tunnel client (exact match — jangan sentuh tunnel client lain)
if ! pgrep -f "tunnel-client[.]mjs" > /dev/null 2>&1; then
  bash "$ROOT/restart-tunnel.sh" > /dev/null 2>&1
  STARTED="$STARTED tunnel"
fi

# 3. Telegram gateway
if ! ps aux | grep "[g]ateway.*run" > /dev/null 2>&1; then
  bash "$ROOT/start-gateway.sh" > /dev/null 2>&1
  STARTED="$STARTED gateway"
fi

echo "--- status ---"
if curl -s -m 8 -o /dev/null http://127.0.0.1:20128/dashboard; then
  echo "OK   9Router (127.0.0.1:20128)"
else
  echo "DOWN 9Router (127.0.0.1:20128)"
fi
if pgrep -f "tunnel-client[.]mjs" > /dev/null 2>&1; then
  echo "OK   tunnel client"
else
  echo "DOWN tunnel client"
fi
if ps aux | grep "[g]ateway.*run" > /dev/null 2>&1; then
  echo "OK   Telegram gateway"
else
  echo "DOWN Telegram gateway"
fi

if [ -n "$STARTED" ]; then
  echo "[$(date -u '+%F %H:%M:%S')] start-all started:$STARTED" >> "$ROOT/boot.log"
fi
