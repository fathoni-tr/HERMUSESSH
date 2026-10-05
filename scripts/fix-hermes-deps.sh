#!/bin/bash
# fix-hermes-deps.sh — Install Python dependencies yang hilang ke bundled Python hermes
# Masalah: setelah VM di-replace, modul Python (ruamel.yaml, dotenv, rich) hilang
# dari bundled Python di ~/.hermes/tools/, menyebabkan "ModuleNotFoundError"
#
# Cara pakai: bash fix-hermes-deps.sh

HATCH_HOME="${HATCH_HOME:-/home/hatch}"
HERMES_PY=$(ls -d $HATCH_HOME/.hermes/tools/python-*/bin/python3 2>/dev/null | head -1)

if [ -z "$HERMES_PY" ]; then
    echo "Bundled Python hermes tidak ditemukan di $HATCH_HOME/.hermes/tools/" >&2
    exit 1
fi

echo "Menggunakan: $HERMES_PY"
$HERMES_PY -m pip install --quiet ruamel.yaml python-dotenv rich 2>&1 | grep -v "WARNING: Running pip"
echo "Dependencies terinstall. Test: hermes --help"
