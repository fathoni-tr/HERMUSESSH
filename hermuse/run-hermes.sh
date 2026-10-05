#!/bin/bash
# Menjalankan Hermes CLI (terinstall di ~/.local/bin).
export PATH="$HOME/.local/bin:$PATH"
export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"

# Daftar no_proxy minimal. (Catatan: entri IPv6 bracket seperti [::1]
# di no_proxy membuat httpx crash dengan "Invalid port" — pakai daftar
# minimal yang aman ini.)
export no_proxy="localhost,127.0.0.1"
export NO_PROXY="localhost,127.0.0.1"

exec hermes "$@"
