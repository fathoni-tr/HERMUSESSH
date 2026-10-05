#!/bin/bash
# fix-duplicate-tunnel.sh — Bersihkan tunnel duplikat setelah VM replace
# Masalah: setelah VM di-replace, bisa ada 2+ reverse-tunnel.sh dan koneksi SSH
# yang berebut port 2223 di laptop, menyebabkan "Connection refused".
#
# Cara pakai: bash fix-duplicate-tunnel.sh (sebagai root)

# Kill semua reverse-tunnel.sh (pakai ps+grep agar tidak bunuh diri sendiri)
for pid in $(ps aux | grep "[r]everse-tunnel.sh" | awk '{print $2}'); do
    kill $pid 2>/dev/null && echo "Killed tunnel script PID $pid"
done

# Kill semua koneksi SSH ke laptop
for pid in $(ps aux | grep "[L]enovo@100.101.211.43" | awk '{print $2}'); do
    kill $pid 2>/dev/null && echo "Killed SSH PID $pid"
done

sleep 3

# Start SATU tunnel bersih
RP_HOME="$HOME/workspace/muse-vps-tailscale"
if [ -f "$RP_HOME/reverse-tunnel.sh" ]; then
    nohup "$RP_HOME/reverse-tunnel.sh" > /dev/null 2>&1 &
    disown
    echo "Tunnel baru dimulai (PID $!)"
else
    echo "reverse-tunnel.sh tidak ditemukan di $RP_HOME" >&2
    exit 1
fi
