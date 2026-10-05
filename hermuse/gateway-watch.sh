#!/bin/bash
# gateway-watch.sh — watchdog anti-stall untuk Telegram gateway Hermes.
#
# Masalah yang diatasi: polling Telegram bisa macet padahal proses masih
# hidup — watchdog biasa (watchdog.sh) hanya cek "proses ada/tidak", jadi
# stall diam-diam tidak terdeteksi.
#
# Tiga lapis deteksi (konservatif):
#  1. PID gateway tidak ada -> restart langsung.
#  2. Heartbeat event-loop ($HERMES_HOME/state/gateway.heartbeat, ditulis
#     otomatis oleh gateway Hermes) basi >120 detik atau pid-nya tidak
#     cocok -> loop macet -> restart langsung.
#  3. Heartbeat segar TAPI tidak ada aktivitas adapter Telegram di gateway.log
#     selama 15 menit terakhir (dan, kalau PROXY_PORT diisi, tidak ada koneksi
#     ESTABLISHED milik PID gateway ke port itu) -> polling task macet.
#     Butuh konfirmasi 2 run beruntun sebelum restart, untuk menghindari
#     false positive saat sampling tepat di jeda long-poll.
#
# ATURAN KERAS: hanya kill PID gateway yang exact (satu match pgrep).
# Kalau pgrep menemukan 0 atau >1 kandidat -> JANGAN kill, log + exit non-zero.
# Tidak menyentuh 9Router sama sekali.
#
# Env:
#   DRY_RUN=1       -> hanya deteksi + log, tidak kill/restart.
#   HERMES_HOME     -> home Hermes (default: $HOME/.hermes, sama seperti
#                      run-hermes.sh). File heartbeat dibaca dari
#                      $HERMES_HOME/state/gateway.heartbeat
#   GATEWAY_PGREP   -> pola pgrep -f untuk menemukan proses gateway
#                      (default: [g]ateway.*run, cocok dengan
#                      "./run-hermes.sh gateway run" dari start-gateway.sh)
#   PROXY_PORT      -> kalau trafik Telegram lewat proxy lokal, isi portnya
#                      (mis. 3128) untuk cek koneksi; kosongkan untuk skip
#                      cek koneksi (hanya pakai aktivitas log).
#
# Cron yang disarankan (tiap 5 menit):
#   */5 * * * * /path/ke/Hermuse/gateway-watch.sh
# Log: gateway-watch.log di folder ini (hanya aksi/perubahan).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
D="$SCRIPT_DIR"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
LOG="$D/gateway-watch.log"
HB="$HERMES_HOME/state/gateway.heartbeat"
GLOG="$D/gateway.log"
SUSPECT="$D/.gateway-watch.suspect"
LOCKF="$D/.gateway-watch.lock"
DRY_RUN=${DRY_RUN:-0}
GATEWAY_PGREP="${GATEWAY_PGREP:-[g]ateway.*run}"
HB_MAX_AGE=120      # detik; heartbeat ditulis tiap ~30 dtk
TGLOG_WINDOW=900    # detik; aktivitas adapter Telegram di log
PROXY_PORT="${PROXY_PORT:-}"

log() { echo "[$(date -u '+%F %H:%M:%S')] $*" >> "$LOG"; }
say() { echo "$*"; log "$*"; }

# cegah overlap antar run cron
exec 9>"$LOCKF"
flock -n 9 || exit 0

gw_pids() { pgrep -f "$GATEWAY_PGREP"; }

do_restart() { # $1 = alasan
  local reason="$1"
  local pids n pid
  pids=$(gw_pids); n=$(printf '%s' "$pids" | grep -c .)
  if [ "$n" -eq 0 ]; then
    pid=""
  elif [ "$n" -eq 1 ]; then
    pid=$pids
  else
    say "ABORT: $n kandidat PID gateway, tidak kill (ambiguous): $pids"
    return 1
  fi
  if [ -n "$pid" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      say "DRY_RUN: would kill exact gateway PID $pid ($reason)"
    else
      kill "$pid" 2>/dev/null
      local i
      for i in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
      if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; sleep 1; fi
      if kill -0 "$pid" 2>/dev/null; then
        say "GAGAL: PID $pid tidak bisa di-kill"
        return 1
      fi
      log "killed exact gateway PID $pid ($reason)"
    fi
  else
    log "PID gateway tidak ada ($reason)"
  fi
  if [ "$DRY_RUN" = "1" ]; then
    say "DRY_RUN: would run start-gateway.sh + verifikasi Connected"
    return 0
  fi
  local start_str
  start_str=$(date -u '+%F %H:%M:%S')
  bash "$D/start-gateway.sh" >/dev/null 2>&1
  # verifikasi: baris "Connected to Telegram" yang LEBIH BARU dari waktu
  # restart, maksimal 60 detik
  local ok=0
  for i in $(seq 1 12); do
    sleep 5
    if awk -v s="$start_str" 'index($0,"Connected to Telegram"){ts=substr($0,1,19); if(ts>s) f=1} END{exit !f}' "$GLOG" 2>/dev/null; then
      ok=1; break
    fi
  done
  rm -f "$SUSPECT"
  if [ "$ok" = "1" ]; then
    say "RESTART OK: gateway hidup kembali + Connected to Telegram ($reason)"
    return 0
  fi
  say "RESTART GAGAL: tidak ada 'Connected to Telegram' dalam 60 dtk ($reason)"
  return 1
}

# ---- cek 1: PID ----
pids=$(gw_pids); npid=$(printf '%s' "$pids" | grep -c .)
if [ "$npid" -eq 0 ]; then
  do_restart "PID gateway tidak hidup"; exit $?
elif [ "$npid" -gt 1 ]; then
  say "ABORT: $npid kandidat PID gateway (ambiguous), tidak diapa-apakan: $pids"; exit 1
fi
PID=$pids

# ---- cek 2: heartbeat event-loop ----
hb_ok=0
if [ -f "$HB" ]; then
  hb_ts=$(python3 -c "import json;print(json.load(open('$HB'))['updated_at'])" 2>/dev/null)
  hb_pid=$(python3 -c "import json;print(json.load(open('$HB'))['pid'])" 2>/dev/null)
  if [ -n "$hb_ts" ] && [ "$hb_pid" = "$PID" ]; then
    hb_epoch=$(date -d "$hb_ts" +%s 2>/dev/null)
    now_epoch=$(date -u +%s)
    if [ -n "$hb_epoch" ] && [ $((now_epoch - hb_epoch)) -lt $HB_MAX_AGE ]; then
      hb_ok=1
    fi
  fi
fi
if [ "$hb_ok" = "0" ]; then
  do_restart "heartbeat event-loop basi/hilang (pid file: ${hb_pid:-?}, ts: ${hb_ts:-?})"; exit $?
fi

# ---- cek 3: polling Telegram beneran jalan? ----
stall=1
# 3a. aktivitas adapter Telegram di log dalam TGLOG_WINDOW terakhir
# (connect / reconnect / network error = bukti subsystem polling bernyawa).
cutoff=$(date -u -d "@$(( $(date -u +%s) - TGLOG_WINDOW ))" '+%F %H:%M:%S')
tglog=$(awk -v c="$cutoff" 'index($0,"platforms__telegram.adapter"){ts=substr($0,1,19); if(ts>c) n++} END{print n+0}' "$GLOG" 2>/dev/null)
if [ "$tglog" -gt 0 ]; then
  stall=0
elif [ -n "$PROXY_PORT" ]; then
  # 3b. (opsional) koneksi ESTABLISHED milik PID gateway ke proxy lokal.
  conns=$(ss -tnp 2>/dev/null | grep ":${PROXY_PORT} " | grep -c "pid=${PID}" || true)
  if [ "$conns" -gt 0 ]; then
    stall=0
  fi
fi

if [ "$stall" = "1" ]; then
  if [ -f "$SUSPECT" ]; then
    do_restart "polling stall terkonfirmasi 2 run beruntun (0 aktivitas adapter Telegram 15 mnt)"; exit $?
  fi
  date -u +%s > "$SUSPECT"
  say "SUSPECT: heartbeat segar tapi 0 aktivitas adapter Telegram 15 mnt (pid $PID) — tunggu konfirmasi run berikut"
  exit 0
fi
rm -f "$SUSPECT"
# sehat: diam
exit 0
