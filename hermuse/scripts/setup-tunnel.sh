#!/usr/bin/env bash
# Setup Cloudflare polling tunnel: Pages project + D1 + secret + deploy + key lokal.
# Prasyarat: wrangler login ATAU CLOUDFLARE_API_TOKEN di environment.
# Token Cloudflare dipakai transient saja — tidak disimpan di file mana pun.
#
# Cara pakai:
#   bash scripts/setup-tunnel.sh <nama-pages-project> <nama-d1>
# Contoh:
#   bash scripts/setup-tunnel.sh 9router-tunnel-kamu tunnel-9router
set -euo pipefail

log() { printf '\033[1;32m[tunnel-setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[tunnel-setup]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[tunnel-setup]\033[0m %s\n' "$*" >&2; exit 1; }

PROJECT="${1:-}"; DB_NAME="${2:-}"
[ -n "$PROJECT" ] && [ -n "$DB_NAME" ] || die "Pakai: $0 <nama-pages-project> <nama-d1>"

command -v wrangler >/dev/null 2>&1 || die "wrangler belum terinstall (npm i -g wrangler)."
command -v node >/dev/null 2>&1 || die "node belum terinstall."
[ -n "${CLOUDFLARE_API_TOKEN:-}" ] || warn "CLOUDFLARE_API_TOKEN tidak di-set; wrangler akan pakai login browser bila perlu."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUNNEL_DIR="$SCRIPT_DIR/../tunnel"
PAGES_DIR="$TUNNEL_DIR/pages-tunnel"
KEY_FILE="$HOME/.tunnel-key"

# --- 1. Generate tunnel key (disimpan 600, tidak pernah di-commit) ---
if [ -f "$KEY_FILE" ]; then
  warn "Key sudah ada di $KEY_FILE — pakai yang lama."
else
  log "Generate tunnel key baru..."
  openssl rand -hex 32 > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
fi
TUNNEL_KEY="$(cat "$KEY_FILE")"

# --- 2. Buat D1 database ---
log "Membuat D1 database '$DB_NAME'..."
if ! wrangler d1 list 2>/dev/null | grep -q "$DB_NAME"; then
  wrangler d1 create "$DB_NAME"
else
  warn "D1 '$DB_NAME' sudah ada — lewati create."
fi

# --- 3. Terapkan skema ---
log "Menerapkan schema.sql ke D1..."
wrangler d1 execute "$DB_NAME" --remote --file="$TUNNEL_DIR/schema.sql"

# --- 4. Siapkan wrangler.toml dari template ---
DB_ID="$(wrangler d1 list 2>/dev/null | grep -A1 "$DB_NAME" | grep -oE '[0-9a-f-]{36}' | head -1)"
[ -n "$DB_ID" ] || die "Gagal membaca database_id D1."
sed -e "s/^name = .*/name = \"$PROJECT\"/" \
    -e "s/^database_name = .*/database_name = \"$DB_NAME\"/" \
    -e "s/^database_id = .*/database_id = \"$DB_ID\"/" \
    "$PAGES_DIR/wrangler.toml.example" > "$PAGES_DIR/wrangler.toml"
log "wrangler.toml dibuat untuk project '$PROJECT'."

# --- 5. Buat Pages project bila belum ada ---
log "Memastikan Pages project '$PROJECT' ada..."
wrangler pages project create "$PROJECT" --production-branch=main 2>/dev/null \
  || warn "Pages project '$PROJECT' sudah ada — lanjut."

# --- 6. Set TUNNEL_KEY sebagai Pages secret ---
log "Menyetel TUNNEL_KEY sebagai Pages secret (production)..."
printf '%s' "$TUNNEL_KEY" | wrangler pages secret put TUNNEL_KEY --project-name="$PROJECT"

# --- 7. Deploy Pages Functions ---
log "Deploy ke Pages..."
(cd "$PAGES_DIR" && wrangler pages deploy . --project-name="$PROJECT")

BASE_URL="https://${PROJECT}.pages.dev"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
log "Selesai! Tunnel URL: $BASE_URL"

cat << EOF

============================================================
 Selesai! Tunnel URL: $BASE_URL

 Langkah berikutnya (dari root repo ini):
  1. Pastikan 9Router jalan:  bash restart-9router.sh
  2. Simpan URL tunnel: echo -n '$BASE_URL' > .tunnel-url && chmod 600 .tunnel-url
  3. Jalankan tunnel client: bash restart-tunnel.sh
     (atau manual: TUNNEL_BASE_URL=$BASE_URL TUNNEL_KEY_FILE=$KEY_FILE node tunnel-client.mjs)
  4. Jalankan gateway Telegram: bash start-gateway.sh
  5. Pasang watchdog di cron: */5 * * * * $REPO_ROOT/watchdog.sh
  6. PENTING: ganti password dashboard 9Router dari default!
============================================================
EOF
