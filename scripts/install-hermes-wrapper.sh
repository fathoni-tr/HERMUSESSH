#!/bin/bash
# install-hermes-wrapper.sh — Pasang wrapper /usr/local/bin/hermes
# - hermes tanpa argumen = hermes chat (interactive)
# - Pakai config dari HERMES_HOME=/home/hatch/.hermes (agar root bisa pakai config hatch)
# - Harus dijalankan sebagai root

if [ "$(id -u)" != "0" ]; then
    echo "Jalankan sebagai root: sudo $0" >&2
    exit 1
fi

HATCH_HOME="${HATCH_HOME:-/home/hatch}"

cat > /usr/local/bin/hermes << WEOF
#!/bin/sh
# Wrapper: hermes tanpa argumen = hermes chat, pakai config hatch user
export HERMES_HOME=$HATCH_HOME/.hermes
export HOME=$HATCH_HOME
if [ \$# -eq 0 ]; then
    exec $HATCH_HOME/.local/bin/hermes chat "\$@"
else
    exec $HATCH_HOME/.local/bin/hermes "\$@"
fi
WEOF
chmod +x /usr/local/bin/hermes
echo "Wrapper hermes dipasang di /usr/local/bin/hermes"
