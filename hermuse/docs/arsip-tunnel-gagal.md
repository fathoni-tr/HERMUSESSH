# Arsip: cloudflared & Tailscale yang gagal di jaringan VM asal

Di jaringan VM asal (sandbox dengan egress yang di-intercept), dua cara standar
membuat 9Router bisa diakses dari internet **gagal total**. Keduanya didokumentasikan
di sini sebagai arsip — dan sebagai pengingat bahwa di VM/jaringan normal,
keduanya kemungkinan besar justru cara yang paling sederhana.

Solusi yang akhirnya dipakai: tunnel polling HTTPS murni (Pages Functions + D1),
lihat README utama.

## 1. Cloudflare Tunnel (`cloudflared`) — gagal

Skema yang dicoba:

```yaml
# tunnel-config.yml (contoh, disanitasi)
edge:
  - <IP_EDGE_CLOUDFLARE_1>:7844
  - <IP_EDGE_CLOUDFLARE_2>:7844
ingress:
  - hostname: <HOSTNAME_KAMU>
    service: http://127.0.0.1:20128
  - service: http_status:404
protocol: http2
```

```bash
# start-tunnel.sh (contoh — JANGAN taruh token asli di script)
TOKEN=$(cat ~/.tunnel-token)   # file 600, berisi token hasil `cloudflared tunnel create`
exec cloudflared tunnel --no-autoupdate --config tunnel-config.yml run --token "$TOKEN"
```

Kenapa gagal di jaringan tersebut:

- UDP/QUIC diblokir → transport QUIC mati total.
- Koneksi TLS langsung ke IP edge Cloudflare di-intercept (MITM) → handshake
  dengan edge gagal. (IP edge sempat di-hardcode karena DNS sandbox tidak bisa
  resolve edge discovery; tetap tidak membantu.)
- Dipaksa `protocol: http2` sebagai fallback — tetap gagal.
- Proxy egress menolak `CONNECT` ke port 7844.

Catatan untuk jaringan normal: daftarkan tunnel (`cloudflared tunnel create`),
lalu buat DNS CNAME `<nama>` -> `<TUNNEL_ID>.cfargotunnel.com` di zone
Cloudflare milikmu.

## 2. Tailscale — gagal

Tailscale diinstall dan dicoba join tailnet, tetapi control plane-nya gagal
menembus jaringan tersebut (HTTP 400 dari control plane akibat koneksi
di-MITM). Dicoba 2x, gagal dua-duanya.

Di jaringan normal, Tailscale umumnya langsung jalan dan merupakan cara
termudah mengakses dashboard 9Router secara privat.
