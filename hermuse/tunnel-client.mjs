// Tunnel client: poll Pages -> forward ke 9Router lokal -> kirim response balik.
// Murni HTTPS polling (untuk jaringan yang memblokir WebSocket/QUIC).
//
// Konfigurasi via environment:
//   TUNNEL_BASE_URL   wajib   — URL Pages project, mis. https://<project-kamu>.pages.dev
//   TUNNEL_KEY_FILE   opsional — file berisi tunnel key, default ~/.tunnel-key (permission 600)
//   TUNNEL_LOCAL      opsional — target lokal, default http://127.0.0.1:20128
//   TUNNEL_POLL_MS    opsional — jeda tambahan antar long-poll saat antrean kosong,
//                                default 400. Sejak server pakai long-poll (~20 detik
//                                menahan koneksi), nilai ini BUKAN interval polling
//                                utama — hanya jeda singkat sebelum poll berikutnya.
import { readFileSync } from "node:fs";

const BASE = (process.env.TUNNEL_BASE_URL || "").replace(/\/$/, "");
const KEY_FILE = process.env.TUNNEL_KEY_FILE || (process.env.HOME + "/.tunnel-key");
const LOCAL = process.env.TUNNEL_LOCAL || "http://127.0.0.1:20128";
const POLL_MS = parseInt(process.env.TUNNEL_POLL_MS || "400", 10);

if (!BASE) {
  console.error("TUNNEL_BASE_URL belum di-set. Contoh:");
  console.error("  TUNNEL_BASE_URL=https://<project-kamu>.pages.dev node tunnel-client.mjs");
  console.error("  (atau simpan URL di file .tunnel-url bila dijalankan via start-pages-tunnel.sh)");
  process.exit(1);
}

let KEY;
try {
  KEY = readFileSync(KEY_FILE, "utf8").trim();
} catch {
  console.error(`Tidak bisa baca key file: ${KEY_FILE} (buat dengan: openssl rand -hex 32 > ${KEY_FILE} && chmod 600 ${KEY_FILE})`);
  process.exit(1);
}
if (!KEY) {
  console.error(`Key kosong di ${KEY_FILE}`);
  process.exit(1);
}

async function api(path, body) {
  const r = await fetch(BASE + path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ key: KEY, ...body }),
  });
  if (!r.ok) throw new Error(`tunnel api ${path}: ${r.status}`);
  return r.json();
}

async function handleOne(req) {
  const { id, method, path, headers, body } = req;
  try {
    const h = { ...JSON.parse(headers || "{}") };
    delete h["host"];
    const init = { method, headers: h };
    if (body && method !== "GET" && method !== "HEAD") init.body = Buffer.from(body, "base64");
    const r = await fetch(LOCAL + path, init);
    const buf = Buffer.from(await r.arrayBuffer());
    const resHeaders = {};
    r.headers.forEach((v, k) => { resHeaders[k] = v; });
    await api("/__tunnel/respond", {
      id, status_code: r.status, headers: resHeaders,
      body: buf.length ? buf.toString("base64") : null,
    });
  } catch (e) {
    await api("/__tunnel/respond", {
      id, status_code: 502,
      headers: { "content-type": "text/plain" },
      body: Buffer.from("tunnel client error: " + e.message).toString("base64"),
    }).catch(() => {});
  }
}

console.log("tunnel client ->", BASE, "->", LOCAL);
let fails = 0;
for (;;) {
  try {
    const { requests } = await api("/__tunnel/poll", { limit: 6 });
    fails = 0;
    if (requests && requests.length) {
      await Promise.all(requests.map(handleOne));
    } else {
      await new Promise((r) => setTimeout(r, POLL_MS));
    }
  } catch (e) {
    fails++;
    console.error("poll error:", e.message);
    await new Promise((r) => setTimeout(r, Math.min(1000 * fails, 10000)));
  }
}
