#!/bin/bash
# Restart tunnel client detached.
# Pola pgrep "[.]" (bracket) punya dua fungsi:
#   1. tidak bunuh diri sendiri — regex "tunnel-client[.]mjs" tidak cocok dengan
#      teks literal "tunnel-client[.]mjs" di command line pgrep itu sendiri;
#   2. exact — tidak ikut membunuh tunnel client lain di setup multi-tunnel
#      (mis. tunnel-client-hermesum.mjs).
# Supervisor ikut dibunuh dulu supaya client tidak dobel: kalau supervisor
# lama masih hidup, ia bisa menghidupkan ulang client-nya sendiri sementara
# script ini juga menyalakan supervisor baru.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SP=$(pgrep -f "start-pages-tunnel[.]sh" || true)
if [ -n "$SP" ]; then kill $SP; sleep 1; fi
P=$(pgrep -f "tunnel-client[.]mjs" || true)
if [ -n "$P" ]; then kill $P; sleep 2; fi
setsid nohup bash "$SCRIPT_DIR/start-pages-tunnel.sh" \
  > "$SCRIPT_DIR/pages-tunnel.log" 2>&1 < /dev/null &
echo "tunnel supervisor restarted"
