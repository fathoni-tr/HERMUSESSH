# HERMUSESSH

![HERMUSESSH banner](banner.svg)

**AI agent stack + SSH remote access untuk VM Muse — dalam satu repo.**

## Isi Repo

```
HERMUSESSH/
├── hermuse/                    # AI agent stack (Hermes + 9Router + Telegram)
│   ├── run-hermes.sh           # Jalankan Hermes agent
│   ├── start-9router.sh        # LLM gateway di :20128
│   ├── start-gateway.sh        # Telegram bot gateway
│   ├── scripts/                # install.sh, start-all.sh, doctor.sh, dst.
│   ├── lib/                    # Library pendukung (i18n)
│   ├── tunnel/                 # Tunnel helpers
│   └── docs/                   # Dokumentasi lengkap
├── ssh/
│   ├── cloudflare-tunnel/      # SSH via Cloudflare Tunnel
│   │   ├── tcprelay.py         # TCP relay via egress proxy
│   │   ├── dns.py              # DNS server untuk SRV edge discovery
│   │   ├── rp-boot.sh          # Boot script tunnel
│   │   └── restore-after-replace.sh
│   └── tailscale-reverse/      # SSH via Tailscale reverse tunnel ✅
│       ├── reverse-tunnel.sh   # Tunnel utama (auto-reconnect)
│       ├── setup-sshd.sh       # Setup sshd di VM
│       ├── windows-setup.ps1   # Setup laptop Windows
│       └── tsconnect.py        # ProxyCommand helper
├── scripts/
│   └── vm-boot.sh              # Master auto-recovery semua service
└── docs/                       # Tutorial lengkap
```

## Bagian 1: Hermuse (AI Agent)

Self-hosted AI agent stack: Hermes Agent + 9Router (LLM gateway) + Telegram gateway.

```bash
cd hermuse
bash scripts/install.sh   # Install pertama kali
bash start-9router.sh     # LLM gateway di 127.0.0.1:20128
bash start-gateway.sh     # Telegram bot gateway
bash run-hermes.sh        # Hermes agent
```

Lihat `hermuse/docs/` untuk dokumentasi lengkap.

## Bagian 2: SSH via Tailscale Reverse ✅

Cara yang terbukti jalan. VM nelepon keluar ke laptop via Tailscale,
membuka reverse tunnel: `laptop:2223 → VM:22`.

**Di laptop Windows (sekali jalan):**
```powershell
# PowerShell sebagai Administrator:
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd; Set-Service sshd -StartupType Automatic
New-NetFirewallRule -Name "SSH-Tailscale" -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress 100.64.0.0/10 -Action Allow
```
```cmd
:: CMD biasa:
ssh-keygen -t ed25519 -f %USERPROFILE%\.ssh\muse-key -N ""
```

**Di VM:**
```bash
# 1. Bikin kunci VM -> laptop
ssh-keygen -t ed25519 -f ~/workspace/muse-vps-tailscale/vm-to-laptop-key -N ""
# 2. Tempel vm-to-laptop-key.pub ke C:\ProgramData\ssh\administrators_authorized_keys di laptop
# 3. Tempel muse-key.pub (dari laptop) ke /root/.ssh/authorized_keys di VM
# 4. Jalankan tunnel
bash ssh/tailscale-reverse/reverse-tunnel.sh &
```

**Konek tiap hari:**
```cmd
ssh -i %USERPROFILE%\.ssh\muse-key -p 2223 root@127.0.0.1
```

Tutorial detail: [docs/TAILSCALE-TUTORIAL.id.md](docs/TAILSCALE-TUTORIAL.id.md)

## Bagian 3: SSH via Cloudflare Tunnel

Alternatif jika punya domain. Butuh tunnel token dari dashboard Cloudflare.

```bash
cd ssh/cloudflare-tunnel
# Siapkan hosts, resolv.conf, .token lalu:
bash rp-boot.sh
```

Tutorial detail: [docs/MUSESSH-README.md](docs/MUSESSH-README.md)

> **Catatan:** Cloudflare Tunnel saat ini terblokir oleh egress proxy
> yang me-reset TLS fingerprint Go. Tailscale Reverse adalah jalur utama.

## Auto-Recovery

`scripts/vm-boot.sh` dijalankan watchdog tiap 5 menit. Otomatis me-reinstall
dan me-restart yang mati: **sshd, 9Router, Telegram gateway, 9remote,
reverse SSH tunnel**. Semua file persistent di `~/workspace`.

## Perbandingan Jalur SSH

|  | Tailscale Reverse | Cloudflare Tunnel |
|---|---|---|
| Syarat | Tailscale + OpenSSH di laptop | Domain + Cloudflare account |
| Perintah konek | `ssh -i muse-key -p 2223 root@127.0.0.1` | `ssh root@ssh.domainmu.id` |
| Setup laptop | Sekali (firewall + kunci) | Tidak ada |
| Status | ✅ Jalan | ⚠️ Terblokir proxy |

## Troubleshooting (dari pengalaman 2026-10-05)

### `hermes: command not found` saat SSH sebagai root
Binary ada di `/home/hatch/.local/bin/hermes` (tidak di PATH root).
Fix: `bash scripts/install-hermes-wrapper.sh` (sebagai root) — memasang
wrapper `/usr/local/bin/hermes` yang otomatis masuk mode `chat` dan memakai
config dari `/home/hatch/.hermes`.

### `ModuleNotFoundError: No module named 'ruamel'` (atau dotenv, rich)
Bundled Python hermes (`~/.hermes/tools/python-*/bin/python3`) kehilangan
dependencies setelah VM di-replace. Fix:
```bash
bash scripts/fix-hermes-deps.sh
```

### `It looks like Hermes isn't configured yet` padahal sudah setup
Config ada di `/home/hatch/.hermes/` (milik user hatch), tapi dijalankan
sebagai root. Wrapper `install-hermes-wrapper.sh` sudah menangani ini
dengan `export HERMES_HOME=/home/hatch/.hermes`.

### Gemini API 429 (quota habis)
Ganti ke OpenRouter:
```bash
bash scripts/setup-openrouter.sh <OPENROUTER_API_KEY> [MODEL_ID]
# Contoh: bash scripts/setup-openrouter.sh sk-or-v1-xxxx openrouter/stealth/space-bunny-alpha
```
Script ini menambah provider OpenRouter ke 9Router, restart 9Router,
dan update default model di `~/.hermes/config.yaml`.
API key tidak disimpan di repo — hanya di database 9Router.

### SSH `Connection refused` pada port 2223 setelah VM replace
Kemungkinan ada tunnel duplikat berebut port. Fix dari VM:
```bash
bash ssh/tailscale-reverse/fix-duplicate-tunnel.sh
```

### SSH `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!`
VM ke-replace → host key baru. Dari laptop (PowerShell/CMD):
```cmd
ssh-keygen -R [127.0.0.1]:2223
```

## Lisensi

MIT
