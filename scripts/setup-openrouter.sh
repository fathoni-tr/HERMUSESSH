#!/bin/bash
# setup-openrouter.sh — Tambah OpenRouter sebagai provider di 9Router
# dan set default model Hermes ke model OpenRouter.
#
# Cara pakai: bash setup-openrouter.sh <OPENROUTER_API_KEY> [MODEL_ID]
# Contoh: bash setup-openrouter.sh sk-or-v1-xxxx openrouter/stealth/space-bunny-alpha
#
# API key TIDAK disimpan di repo — hanya di database 9Router.

if [ -z "$1" ]; then
    echo "Cara pakai: $0 <OPENROUTER_API_KEY> [MODEL_ID]" >&2
    exit 1
fi

API_KEY="$1"
MODEL_ID="${2:-openrouter/stealth/space-bunny-alpha}"
HATCH_HOME="${HATCH_HOME:-/home/hatch}"
DB="$HATCH_HOME/.9router/db/data.sqlite"

python3 << PYEOF
import sqlite3, json, uuid, datetime

db = sqlite3.connect("$DB")
api_key = "$API_KEY"
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
data = json.dumps({"apiKey": api_key, "testStatus": "untested"})

cur = db.cursor()
cur.execute("SELECT id FROM providerConnections WHERE provider='openrouter'")
row = cur.fetchone()

if row:
    cur.execute("UPDATE providerConnections SET data=?, updatedAt=? WHERE provider='openrouter'", (data, now))
    print("OpenRouter provider diupdate")
else:
    pid = str(uuid.uuid4())
    cur.execute(
        "INSERT INTO providerConnections (id, provider, authType, name, priority, isActive, data, createdAt, updatedAt) VALUES (?,?,?,?,?,?,?,?,?)",
        (pid, "openrouter", "apiKey", "OpenRouter", 1, 1, data, now, now)
    )
    print("OpenRouter provider ditambahkan")

db.commit()
db.close()
PYEOF

# Restart 9Router agar baca provider baru
cd "$HATCH_HOME/workspace/Hermuse" 2>/dev/null && bash restart-9router.sh 2>&1 | tail -1

# Update default model di config Hermes
CONFIG="$HATCH_HOME/.hermes/config.yaml"
if [ -f "$CONFIG" ]; then
    cp "$CONFIG" "$CONFIG.bak"
    sed -i "s|default: \".*\"|default: \"$MODEL_ID\"|" "$CONFIG"
    echo "Default model Hermes: $MODEL_ID"
fi

echo "Selesai. Test: hermes -z \"halo\""
