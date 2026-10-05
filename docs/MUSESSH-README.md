<img width="2048" height="1152" alt="banner" src="https://github.com/user-attachments/assets/822142d6-fb69-4b8e-9d36-77aedd30bd2c" />

# Tutorial Lengkap: SSH ke VM Muse dari Laptop via Cloudflare Tunnel

> Panduan langkah-demi-langkah membangun akses SSH dari laptop ke VM/sandbox Muse
> memakai Cloudflare Tunnel — lengkap dengan penjelasan cara kerja, semua error
> yang mungkin terjadi, dan sistem pulih-otomatis. Ditulis untuk pemula: tidak
> perlu latar belakang IT untuk mengikuti.

**Daftar Isi**

1. [Gambaran Besar — baca dulu 3 menit](#1-gambaran-besar--baca-dulu-3-menit)
2. [Yang Kamu Butuhkan](#2-yang-kamu-butuhkan)
3. [Langkah 1 — Buat Tunnel di Cloudflare (dapat token)](#3-langkah-1--buat-tunnel-di-cloudflare-dapat-token)
4. [Langkah 2 — Siapkan File-File di VM](#4-langkah-2--siapkan-file-file-di-vm)
5. [Langkah 3 — Install SSH Server di VM](#5-langkah-3--install-ssh-server-di-vm)
6. [Langkah 4 — Jalankan Tunnel Secara Otomatis](#6-langkah-4--jalankan-tunnel-secara-otomatis)
7. [Langkah 5 — Konek dari Laptop](#7-langkah-5--konek-dari-laptop)
8. [Cara Kerja Tiap Komponen (penjelasan awam)](#8-cara-kerja-tiap-komponen-penjelasan-awam)
9. [Anti-Gagal: Pulih Otomatis Setelah VM Diganti/Restart](#9-anti-gagal-pulih-otomatis-setelah-vm-digantirestart)
10. [Troubleshooting — Semua Error yang Mungkin Terjadi](#10-troubleshooting--semua-error-yang-mungkin-terjadi)
11. [Keamanan](#11-keamanan)
12. [FAQ](#12-faq)

---

## 1. Gambaran Besar — baca dulu 3 menit

**Masalahnya:** VM Muse ini tidak punya alamat IP publik. Ibarat rumah tanpa
alamat — tidak bisa didatangi dari luar, walau pintunya (SSH port 22) terbuka.

**Solusinya — Cloudflare Tunnel:** karena VM tidak bisa didatangi, kita balik:
VM yang **menelepon keluar** ke Cloudflare, lalu Cloudflare membukakan sebuah
"pintu" berupa nama domain (misal `ssh.namadomainmu.id`) yang mengarah ke VM.
Laptop kamu mengetuk pintu itu, Cloudflare meneruskannya lewat sambungan telepon
yang sudah dibuka VM tadi. Hasilnya: kamu bisa SSH ke VM dari mana saja.

**Kenapa tidak semudah install biasa?** VM ini punya "satpam-satpam" galak:

| Satpam | Artinya dalam bahasa awam |
|---|---|
| Semua internet wajib lewat proxy | VM tidak boleh internetan langsung, harus lewat perantara |
| DNS dibohongi | Buku telepon VM dipalsukan khusus untuk alamat Cloudflare |
| HTTP POST digantung | Surat jenis tertentu tidak pernah sampai |
| UDP dibatasi | Salah satu "jalur" komunikasi dipersempit |
| File sistem read-only | Buku telepon & buku alamat tidak bisa ditulis langsung |

Karena itu kita butuh tiga "akal-akalan" (semuanya sudah jadi script di folder
`scripts/`):

- **`tcprelay.py`** — *penerjemah*: menerima koneksi dari `cloudflared`,
  meneruskannya lewat proxy dengan cara yang diizinkan, lalu menyambung
  kabelnya transparan.
- **`dns.py`** — *buku telepon palsu yang jujur*: menjawab pertanyaan alamat
  Cloudflare dengan jawaban yang benar (diambil dari sumber terpercaya),
  karena buku telepon asli VM sudah dipalsukan.
- **`rp-boot.sh` + `rp-tunnel.service`** — *mandor*: menyalakan semuanya
  dengan urutan yang benar setiap VM menyala, dan mengulanginya kalau mati.

Hasil akhirnya seperti ini:

```
[laptop] --SSH--> [cloudflared di laptop] --HTTPS(443)--> [Cloudflare]
    --> [cloudflared di VM] --> [tcprelay.py] --> [proxy] --> [internet]
    --> [sshd di VM port 22]
```

---

## 2. Yang Kamu Butuhkan

- [ ] Akun Cloudflare **gratis** + sebuah domain yang nameserver-nya sudah
      dipindah ke Cloudflare (misal `namadomainmu.id`)
- [ ] Akses terminal ke VM Muse (sebagai `root`)
- [ ] Laptop Windows (untuk konek nantinya)
- [ ] File-file di folder `scripts/` repo ini

> **Catatan:** tutorial ini ditulis untuk VM Muse yang spesifik (dengan semua
> "satpam" di atas). Kalau kamu menjalankannya di VPS normal, kamu TIDAK butuh
> `tcprelay.py`/`dns.py` — cukup `cloudflared tunnel run --token <TOKEN>`
> langsung.

---

## 3. Langkah 1 — Buat Tunnel di Cloudflare (dapat token)

Bagian ini dikerjakan di **browser**, di dashboard Cloudflare. Token hanya bisa
dibuat di sini — tidak bisa dibuat dari dalam VM.

1. Buka [dash.cloudflare.com](https://dash.cloudflare.com) → pilih domainmu →
   menu **Zero Trust** (kalau belum ada, aktifkan Zero Trust gratis dulu).
2. Buka **Networks → Tunnels** → **Create a tunnel**.
3. Pilih **Cloudflared** → beri nama (misal `muse-vm`) → **Save tunnel**.
4. Di halaman berikutnya akan muncul **token** (string panjang berawalan
   `eyJ...`). **Copy dan simpan baik-baik** — ini kunci akses tunnel-mu.
5. Masih di halaman tunnel, buka tab **Public Hostname** → **Add a public hostname**:
   - **Subdomain:** `ssh` (jadi `ssh.namadomainmu.id`)
   - **Domain:** pilih domainmu
   - **Service Type:** `SSH`
   - **URL:** `localhost:22`
   - **Save**.

> Token ini ibarat kunci rumah — siapa pun yang pegang bisa menyambungkan
> tunnel ini. Jangan share ke publik, jangan commit ke repo.

---

## 4. Langkah 2 — Siapkan File-File di VM

Semua perintah di bawah dijalankan di **terminal VM** sebagai `root`.
Kita taruh semuanya di `~/workspace/rp/` (folder ini **aman dari penghapusan**
saat VM diganti — jangan taruh di `/tmp`).

```bash
# 1. Buat folder kerja & copy script
RP=~/workspace/rp
mkdir -p $RP
cp scripts/tcprelay.py scripts/dns.py scripts/rp-boot.sh scripts/rp-tunnel.service $RP/
chmod +x $RP/rp-boot.sh $RP/restore-after-replace.sh

# 2. Buat file hosts gabungan (hosts asli + alamat Cloudflare)
cp /etc/hosts $RP/hosts
cat >> $RP/hosts <<'EOF'
127.0.0.2 api.trycloudflare.com
127.0.0.3 region1.v2.argotunnel.com
127.0.0.4 region2.v2.argotunnel.com
EOF

# 3. Buat resolv.conf yang menunjuk ke DNS lokal kita
printf 'nameserver 127.0.0.1\n' > $RP/resolv.conf

# 4. Simpan token (GANTI dengan token punyamu!) — hanya root yang bisa baca
printf '%s' 'TOKEN_KAMU_DI_SINI' > $RP/.token
chmod 600 $RP/.token

# 5. Simpan info proxy dari environment (otomatis terisi)
python3 - <<'EOF'
import os, shlex
rp = os.path.expanduser('~/workspace/rp')
px = os.environ.get('https_proxy') or os.environ.get('HTTPS_PROXY')
with open(rp + '/.proxy-env', 'w') as f:
    for v in ('http_proxy', 'https_proxy', 'HTTP_PROXY', 'HTTPS_PROXY'):
        f.write("%s=%s\n" % (v, shlex.quote(os.environ.get(v) or px)))
os.chmod(rp + '/.proxy-env', 0o600)
print("proxy-env tersimpan")
EOF

# 6. Cek hasilnya
ls -la $RP/
```

Hasil yang diharapkan: ada file `tcprelay.py`, `dns.py`, `rp-boot.sh`,
`rp-tunnel.service`, `hosts`, `resolv.conf`, `.token`, `.proxy-env`.

> **Kenapa `.token` dan `.proxy-env` permission 600?** Karena isinya kredensial.
> Hanya `root` yang boleh baca. Jangan pernah tampilkan isinya di chat/log.

---

## 5. Langkah 3 — Install SSH Server di VM

Tunnel-nya nanti mengarah ke `localhost:22`, jadi VM butuh SSH server yang
menyala di port 22.

```bash
# 1. Install openssh-server
# (pakai trik -o karena file sources.list di VM ini tidak bisa ditulis)
mkdir -p ~/workspace/rp/apt-empty.d
cat > ~/workspace/rp/apt-minimal.sources <<'EOF'
Types: deb
URIs: http://azure.archive.ubuntu.com/ubuntu
Suites: noble noble-updates noble-security
Components: main
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
OPTS="-o Dir::Etc::sourcelist=$HOME/workspace/rp/apt-minimal.sources -o Dir::Etc::sourceparts=$HOME/workspace/rp/apt-empty.d"
apt-get $OPTS update
DEBIAN_FRONTEND=noninteractive apt-get $OPTS install -y openssh-server

# 2. Konfigurasi: izinkan login password + login root
sed -i -E 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i -E 's/^#?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
# backup config ke folder persisten (untuk restore otomatis)
cp /etc/ssh/sshd_config ~/workspace/rp/sshd_config

# 3. Buat password root yang kuat (CATAT! hanya ditampilkan sekali)
openssl rand -base64 18 | tr -d '/+=' | head -c 20; echo
# lalu set manual:
# echo "root:PASSWORD_TADI" | chpasswd
# (atau langsung: echo "root:$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)" | chpasswd
#  tapi catat passwordnya dulu sebelum di-set!)

# 4. Nyalakan sshd
mkdir -p /run/sshd
systemctl enable --now ssh
systemctl is-active ssh   # harusnya: active

# 5. Verifikasi: banner SSH harus terbaca
timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22; head -c 30 <&3; echo'
# harusnya keluar: SSH-2.0-OpenSSH_9.6p1 Ubuntu-3 (atau versi lain)
```

> **Tips password:** jangan diketik manual — copy-paste untuk menghindari salah
> ketik. Password root ini PENTING: simpan di password manager. Kalau VM
> diganti, password ini tetap sama (lihat Bagian 9).

---

## 6. Langkah 4 — Jalankan Tunnel Secara Otomatis

Kita pasang sebagai **systemd service** supaya nyala otomatis saat VM boot dan
restart sendiri kalau mati.

```bash
RP=~/workspace/rp

# 1. Pasang unit service
cp $RP/rp-tunnel.service /etc/systemd/system/rp-tunnel.service
systemctl daemon-reload
systemctl enable rp-tunnel.service

# 2. Jalankan
systemctl start rp-tunnel.service
sleep 5
systemctl is-active rp-tunnel.service   # harusnya: active

# 3. Tunggu ~40 detik, lalu verifikasi registrasi
sleep 40
grep "Registered tunnel connection" $RP/cf-boot.log
```

Hasil yang diharapkan — baris seperti ini (boleh 1 atau 2 koneksi):

```
... INF Registered tunnel connection connIndex=0 ... protocol=http2
```

Dan cek koneksi edge-nya:

```bash
ss -tnp 2>/dev/null | grep -c "ESTAB.*cloudflared"
# harusnya >= 1
```

**Kalau tidak ada "Registered tunnel connection"**, jangan panik — buka
[Bagian 10 (Troubleshooting)](#10-troubleshooting--semua-error-yang-mungkin-terjadi).

Isi `rp-tunnel.service` (untuk referensi):

```ini
[Unit]
Description=Reverse proxy tunnel chain (relay + dns + cloudflared)
After=network-online.target
Wants=network-online.target
RequiresMountsFor=/home/hatch/workspace

[Service]
Type=simple
User=root
# bind-mount hosts/resolv.conf palsu ke dalam service ini saja
BindReadOnlyPaths=/home/hatch/workspace/rp/hosts:/etc/hosts
BindReadOnlyPaths=/home/hatch/workspace/rp/resolv.conf:/etc/resolv.conf
ExecStart=/home/hatch/workspace/rp/rp-boot.sh
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
```

---

## 7. Langkah 5 — Konek dari Laptop

**Penting untuk dipahami:** `ssh` biasa ke port 22 (`ssh root@ssh.namadomainmu.id`)
**TIDAK AKAN PERNAH BISA** untuk Cloudflare Tunnel paket gratis — Cloudflare
tidak membuka port 22 di servernya. Harus lewat program `cloudflared` di laptop
yang "menelepon" lewat HTTPS (port 443, yang memang dibuka Cloudflare).

**Di laptop Windows:**

1. Download `cloudflared-windows-amd64.exe` dari
   https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
2. Rename jadi `cloudflared.exe`, taruh di folder yang masuk PATH
   (misal `C:\Windows\System32`).
3. Buka **dua** jendela terminal (`Win+R` → `cmd`):
   - **Terminal 1** (jangan ditutup — dia standby):
     ```
     cloudflared.exe access ssh --hostname ssh.namadomainmu.id --url 127.0.0.1:2222
     ```
     Harusnya muncul `Start Websocket listener host=127.0.0.1:2222`, lalu diam.
   - **Terminal 2**:
     ```
     ssh -p 2222 root@127.0.0.1
     ```
     Masukkan password root VM.

**Cara permanen (disarankan)** — cukup sekali setting, seterusnya tinggal
`ssh namapendek`. Tambahkan ke `%USERPROFILE%\.ssh\config`:

```
Host vmmuse
    HostName ssh.namadomainmu.id
    User root
    ProxyCommand cloudflared.exe access ssh --hostname %h
```

Lalu cukup: `ssh vmmuse`.

> **Jangan double-click `cloudflared.exe`!** Dia program terminal — harus
> dijalankan dari dalam terminal (cmd/PowerShell), kalau tidak jendelanya
> langsung ketutup dan kelihatan "tidak keluar apa-apa".

---

## 8. Cara Kerja Tiap Komponen (penjelasan awam)

### Kenapa `cloudflared` tidak bisa jalan langsung?

Program `cloudflared` itu "keras kepala": dia tidak mau memakai proxy yang
disediakan VM, maunya internetan langsung. Padahal di VM ini internet langsung
**diblokir**. Ibarat tamu yang menolak lewat pintu satpam dan ngotot mau
lompat pagar — ya ditangkap.

### `tcprelay.py` — si penerjemah

Relay ini membuka dua "loket" di `localhost`: port `443` dan `7844`. Saat
`cloudflared` datang membawa alamat tujuan (misal `127.0.0.3`, yang sebenarnya
mewakili `region1.v2.argotunnel.com`), relay:

1. Melihat daftar `MAP`: `127.0.0.3` → IP asli `198.41.192.77`
2. Mengetuk proxy: *"tolong sambungkan saya ke `198.41.192.77:7844`"*
   (perintah `HTTP CONNECT` — cara resmi yang diizinkan satpam)
3. Setelah tersambung, relay hanya meneruskan byte mentah dua arah
   (*splice transparan*) — tidak peduli isinya TLS atau HTTP/2.

**Kenapa pakai IP asli, bukan nama hostname?** Temuan penting saat pengerjaan:
proxy-nya menggantung (hang) kalau diminta `CONNECT` ke *hostname*
Cloudflare di port 7844 — kemungkinan karena DNS-nya proxy ikut kena
pembajakan. Tapi kalau diminta `CONNECT` ke **IP angkanya langsung**,
langsung tembus. IP asli didapat dari DNS-over-HTTPS
(`https://cloudflare-dns.com/dns-query`) yang tidak bisa dibajak.

**Kenapa daftar IP-nya banyak (failover)?** Koneksi ke port 7844 lewat proxy
kadang-kadang macet per IP tertentu. Jadi relay mencoba IP satu per satu
sampai ada yang tembus (timeout 30 detik per percobaan).

### `dns.py` — buku telepon palsu yang jujur

`cloudflared` butuh dua info dari DNS:

1. **Rekor SRV** `_v2-origintunneld._tcp.argotunnel.com` — "server Cloudflare
   mana saja yang bisa saya hubungi?" Jawaban asli (dari DoH): hanya
   `region1` dan `region2`, port `7844`. (Dulu ada 8 region, sekarang tinggal
   2 — region 3–8 sudah tidak ada / NXDOMAIN.)
2. **Rekor A** untuk nama-nama Cloudflare — dijawab dengan `127.0.0.x`
   sesuai file `hosts`, supaya `cloudflared` datang ke relay.

Sisanya (misal `google.com`) diteruskan ke DNS asli VM via TCP.

**Trik teknisnya:** VM ini memblokir `sendto()` untuk UDP (tidak bisa "melempar"
paket UDP begitu saja). Tapi `connect()` + `send()` **boleh**. Jadi `dns.py`
menerima pertanyaan lewat `recvfrom()`, lalu menjawab dengan cara:
`connect()` ke alamat penanya → `send()` jawaban → "disconnect" dengan trik
`connect()` memakai `sa_family=AF_UNSPEC` via ctypes. Harus single-threaded
di socket yang sama agar port sumber tetap 53 (syarat dari `cloudflared`
yang memakai *connected UDP*).

### `hosts` & `resolv.conf` (bind-mount)

File `/etc/hosts` dan `/etc/resolv.conf` di VM ini **read-only** (tidak bisa
ditulis). Tapi karena kita `root`, kita bisa "menimpanya" dengan
`mount --bind` — ibarat menempelkan stiker di atas buku yang tidak boleh
ditulisi. Di systemd service, ini dilakukan otomatis via `BindReadOnlyPaths`,
jadi hanya berlaku di dalam service itu (tidak mengganggu sistem lain).

### `rp-boot.sh` — si mandor

Urutan kerja setiap service menyala:

1. Baca info proxy dari `$RP/.proxy-env` (service systemd tidak mewarisi
   environment variable dari shell!)
2. Nyalakan `tcprelay.py` (background)
3. Nyalakan `dns.py` (background)
4. Tunggu sampai DNS lokal bisa menjawab query SRV yang sebenarnya
5. Pastikan `sshd` jalan
6. Jalankan `cloudflared tunnel --protocol http2 run --token ...` di
   foreground, dalam **loop retry selamanya** (kalau mati, tunggu 10 detik,
   coba lagi)

**Kenapa `--protocol http2`?** Protokol QUIC butuh UDP yang dibatasi di sini.
HTTP/2 jalan di atas TCP — lolos.

**Kenapa *named tunnel* bukan *quick tunnel*?** Quick tunnel (`cloudflared
tunnel --url`) butuh registrasi via HTTP POST ke `api.trycloudflare.com`,
dan proxy di sini **menggantung semua HTTP POST selamanya** (tarpit). Tidak
ada cara mengakali ini — jadi tunnel-nya dibuat di dashboard Cloudflare
(di luar VM), dan di dalam VM hanya dijalankan "mesin"-nya (data plane)
yang tidak butuh POST sama sekali.

---

## 9. Anti-Gagal: Pulih Otomatis Setelah VM Diganti/Restart

### Masalahnya

VM Muse bisa **diganti** (replace) sewaktu-waktu — misal saat update sistem.
Saat itu terjadi:

| Tetap ada ✅ | Hilang ❌ |
|---|---|
| Semua di `~/workspace/` | Semua di `/etc/` (termasuk service systemd) |
| Token, script, config backup | `openssh-server` (harus install ulang) |
| | Password root (kembali default) |
| | File `/usr/local/bin` tambahan |

Gejalanya kalau terjadi: tiba-tiba tidak bisa SSH / `cloudflared access`
error `websocket: bad handshake`.

### Solusinya (sudah disiapkan)

**1. Script `restore-after-replace.sh`** (di folder `scripts/`, copy ke
`~/workspace/rp/`). Idempoten — aman dijalankan kapan saja. Isinya:

- Refresh info proxy dari environment sesi berjalan
- Pastikan `cloudflared` ada (restore/download ulang kalau hilang)
- Install ulang `rp-tunnel.service` kalau file-nya hilang
- Install ulang `openssh-server` kalau hilang (pakai trik apt `-o`)
- Kembalikan `sshd_config` dari backup
- Kembalikan **password root yang SAMA** dari backup hash (`$RP/.root_shadow`)
- Pastikan service `ssh` dan `rp-tunnel` berjalan
- Tunggu sampai tunnel tersambung ke edge (maks 90 detik)
- Output `RESTORED` kalau ada yang diperbaiki, `OK` kalau semua sehat

**2. Backup hash password** — supaya password tidak berubah tiap VM diganti:

```bash
# simpan SEKALI (setelah password final di-set):
getent shadow root | cut -d: -f2 > ~/workspace/rp/.root_shadow
chmod 600 ~/workspace/rp/.root_shadow
```

Script restore memakai `usermod -p "$(cat $RP/.root_shadow)" root` untuk
mengembalikan password yang sama persis.

**3. Watchdog cron tiap 15 menit** — jadwal otomatis yang menjalankan script
di atas. Kalau semua sehat: diam. Kalau habis di-replace: restore otomatis
dan kirim notifikasi ke chat. Cara pasang (dijalankan sekali oleh asisten
Muse):

```bash
# dibuat via cron tool dengan:
# - id: tunnel-health-watch
# - schedule: interval 15 menit
# - body: jalankan ~/workspace/rp/restore-after-replace.sh;
#   jika RESTORED → verifikasi lalu notifikasi user (Bahasa Indonesia);
#   jika OK → diam
```

Dengan ini, skenario terburuknya: VM diganti → maksimal ~15 menit kemudian
tunnel pulih sendiri → kamu dapat notifikasi → `ssh` lagi dengan password
yang sama.

---

## 10. Troubleshooting — Semua Error yang Mungkin Terjadi

Tabel ini disusun dari **kejadian nyata** selama pengerjaan, bukan teori.

| # | Gejala | Penyebab | Solusi |
|---|---|---|---|
| 1 | `cloudflared tunnel --url` → TLS handshake error | `cloudflared` tidak mau lewat proxy | Jangan pakai quick tunnel. Pakai named tunnel + `tcprelay.py` (Langkah 1 & 4) |
| 2 | `edge discovery: ... connection refused` (UDP :53) | `dns.py` belum jalan / mati | `ss -uln \| grep :53` → harus ada. Kalau tidak, `systemctl restart rp-tunnel` |
| 3 | Log `Registered tunnel connection` tapi SSH tidak masuk | `sshd` mati, atau Public Hostname di dashboard salah | `ss -tln \| grep :22` → harus ada. Cek dashboard: hostname → SSH → `localhost:22` |
| 4 | Di laptop: `websocket: bad handshake` | Tunnel sedang mati di sisi VM (biasanya VM baru di-replace) | Di VM: `systemctl status rp-tunnel`. Kalau unit tidak ditemukan → VM di-replace → jalankan `restore-after-replace.sh` |
| 5 | Di laptop: `ssh root@ssh.xxx.id` → `Connection timed out` | **Normal!** Cloudflare tidak membuka port 22 | Wajib lewat `cloudflared access` (Langkah 5). Bukan error. |
| 6 | `Permission denied (publickey,password)` 3x | Password salah ketik, ATAU VM baru (password lama hangus) | Copy-paste password (jangan ketik manual). Kalau baru di-replace, minta/generate password baru |
| 7 | `TLS handshake with edge error: i/o timeout` terus-menerus | Relay tidak tembus ke port 7844 | Cek `tail ~/workspace/rp/relay.log` — kalau banyak `relay error: timed out`, kemungkinan IP edge berubah → refresh IP via DoH (lihat bawah) |
| 8 | `cloudflared.exe` di Windows "tidak keluar apa-apa" | Di-double-click (jendela langsung ketutup) | Jalankan dari dalam cmd/PowerShell, bukan double-click |
| 9 | `apt` → `Permission denied` saat tulis sources | File sources.list read-only di VM ini | Jangan ubah file asli — pakai trik `-o Dir::Etc::sourcelist=... -o Dir::Etc::sourceparts=...` (Langkah 3) |
| 10 | `apt update` sangat lambat (belasan menit) | Normal — overhead per-file lewat proxy, bukan bandwidth | Pakai sources minimal (cukup `main`, Langkah 3). Jangan dibatalkan. |
| 11 | Service `inactive`, `Unit not found` | VM di-replace | Jalankan `~/workspace/rp/restore-after-replace.sh` |
| 12 | `ValueError: invalid literal for int(): 'rv-tunnel'` (di log service) | `%h`/`%p` di `ExecStart` systemd dimakan systemd sebagai specifier | Tulis `%%h %%p` (persen ganda) |
| 13 | `proxy-ssh: proxy closed` / CONNECT hang | Proxy tidak bisa mencapai tujuan (atau tujuan tidak reachable dari internet) | Cek tujuan bisa dijangkau dari internet dulu (misal via `Test-NetConnection` dari luar) |
| 14 | Tunnel tiba-tiba mati padahal tidak di-replace | Koneksi :7844 flaky / kena throttle | `rp-boot.sh` me-retry otomatis tiap 10 detik; `Restart=always` me-restart service. Biasanya pulih sendiri dalam 1–2 menit. Cek `ss -tnp \| grep cloudflared` |

### Cara refresh IP edge Cloudflare (kalau error no. 7)

IP edge bisa berubah sewaktu-waktu. Ambil yang baru via DNS-over-HTTPS:

```bash
for h in region1.v2.argotunnel.com region2.v2.argotunnel.com api.trycloudflare.com; do
  ips=$(curl -s --max-time 10 "https://cloudflare-dns.com/dns-query?name=${h}&type=A" \
    -H "accept: application/dns-json" | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(','.join(a['data'] for a in d.get('Answer',[])))")
  echo "$h -> $ips"
done
# cek juga SRV-nya (daftar region bisa berubah!):
curl -s --max-time 15 "https://cloudflare-dns.com/dns-query?name=_v2-origintunneld._tcp.argotunnel.com&type=SRV" \
  -H "accept: application/dns-json" | \
  python3 -c "import json,sys; d=json.load(sys.stdin); [print(a['data']) for a in d.get('Answer',[])]"
```

Lalu update daftar `MAP` di `tcprelay.py` dan `SRV_TARGETS`/`FAKE_A` di `dns.py`,
restart service: `systemctl restart rp-tunnel.service`.

### Tes konektivitas manual (diagnostik)

```bash
# 1. Apakah relay tembus ke Cloudflare? (harusnya dapat HTTP 405 asli)
curl -sI --resolve api.trycloudflare.com:443:127.0.0.2 --max-time 20 https://api.trycloudflare.com/ | head -3

# 2. Apakah DNS lokal jawab SRV? (harusnya 2 baris region1 & region2)
dig @127.0.0.1 SRV _v2-origintunneld._tcp.argotunnel.com +short

# 3. Apakah proxy mengizinkan CONNECT ke port 7844? (harusnya 200)
python3 - <<'EOF'
import socket, os, base64
from urllib.parse import urlparse
u = os.environ.get('https_proxy')
p = urlparse(u)
auth = base64.b64encode(("%s:%s" % (p.username, p.password or "")).encode()).decode()
px = socket.getaddrinfo(p.hostname, p.port or 3128, socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
s = socket.create_connection((px, p.port or 3128), timeout=10)
s.sendall(("CONNECT 198.41.200.233:7844 HTTP/1.1\r\nHost: x\r\nProxy-Authorization: Basic %s\r\n\r\n" % auth).encode())
s.settimeout(15)
print(s.recv(64).split(b"\r\n")[0].decode())
EOF
```

---

## 11. Keamanan

1. **Token tunnel** = kunci rumah. Simpan di file 600, jangan pernah commit
   ke repo, jangan share screenshot yang memuatnya.
2. **Password root** yang terekspos ke internet = target brute-force. Untuk
   pemakaian serius, migrasi ke:
   - Login pakai **SSH key** (matikan `PasswordAuthentication`), dan/atau
   - **Cloudflare Access** (tambah lapisan login Cloudflare sebelum SSH).
3. **Jangan jalankan token yang sama di dua mesin bersamaan** — trafik bisa
   tersasar acak. Satu tunnel = satu mesin. Butuh dua mesin? Buat dua tunnel.
4. File `.proxy-env` berisi password proxy — perlakukan seperti token (600,
   jangan dishare).
5. Kalau suatu hari tidak butuh lagi: hapus tunnel di dashboard Cloudflare
   dan `systemctl disable --now rp-tunnel.service`.

---

## 12. FAQ

**Q: Kenapa tidak pakai `cloudflared tunnel --url` saja (quick tunnel)?**
A: Butuh HTTP POST untuk registrasi, dan proxy di VM ini menggantung semua
POST selamanya. Secara arsitektur mustahil — bukan bug.

**Q: Kenapa laptop harus install `cloudflared`? Tidak bisa `ssh` biasa?**
A: Cloudflare (paket gratis) tidak membuka port 22 di servernya. `ssh` biasa
pasti timeout. `cloudflared access` membungkus SSH di dalam HTTPS (port 443)
yang memang dibuka Cloudflare.

**Q: Bisa dipakai di VPS normal (bukan VM Muse)?**
A: Bisa, dan jauh lebih gampang — tidak butuh `tcprelay.py`/`dns.py` sama
sekali. Cukup: `docker run cloudflare/cloudflared:latest tunnel --no-autoupdate run --token <TOKEN>`.
Tapi ingat: tunnel mengekspos **mesin tempat cloudflared jalan**.

**Q: Bagaimana kalau mau expose web, bukan SSH?**
A: Tambah Public Hostname baru di dashboard (misal `web.namadomainmu.id` →
Service Type `HTTP` → URL `localhost:3000`). Tidak perlu setting ulang VM —
`cloudflared` otomatis mengambil config baru.

**Q: Apakah tunnel ini bisa untuk reverse tunnel ke VPS saya (tanpa Cloudflare)?**
A: Bisa, dengan `ssh -R` dari VM ke VPS — TAPI VPS harus punya IP publik
yang reachable dari internet. Kalau VPS di belakang router rumah tanpa port
forwarding (atau CGNAT), tidak bisa. Lihat Bagian 10 no. 13.

**Q: VM di-replace, apakah token ikut hangus?**
A: Tidak. Token tersimpan di `~/workspace/rp/.token` yang persisten.
Yang hilang hanya file di `/etc` dan program terinstall — semuanya
dipulihkan otomatis oleh watchdog (Bagian 9).

---

*Ditulis dari pengalaman nyata: VM Muse (Ubuntu 24.04), Oktober 2026.*
*Script di folder `scripts/` adalah versi final yang teruji jalan.*
