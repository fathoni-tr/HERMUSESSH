#!/bin/bash
# doctor.test.sh — regression tests for scripts/doctor.sh.
#
# Hermetic: every dependency (fake gateway, fake 9Router, fake tunnel URL,
# fake PATH shims, fixture files/heartbeats) is built in a temp dir.
# Needs only bash and node. No network beyond 127.0.0.1.
# Exit 0 iff all tests pass.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCTOR="$SCRIPT_DIR/doctor.sh"
TMP="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$TMP"' EXIT

pass=0
fail=0
t_ok()   { pass=$((pass + 1)); echo "ok   - $1"; }
t_fail() { fail=$((fail + 1)); echo "FAIL - $1"; }

# The pgrep pattern, pinned here AND verified byte-identical to doctor.sh's
# gateway_pids() — the test fails loudly on drift instead of silently
# testing a different pattern than the implementation uses.
# FILE_PAT is the literal source text in doctor.sh (\" stays escaped there);
# PATTERN is the effective regex pgrep receives after bash unescaping.
FILE_PAT="pgrep -f \"[g]ateway['\\\", ]+run\""
PATTERN='[g]ateway['"'"'", ]+run'
if ! grep -qF "$FILE_PAT" "$DOCTOR"; then
  echo "FAIL - pattern drift: doctor.sh's gateway_pids() changed; update FILE_PAT/PATTERN" >&2
  exit 1
fi

# --- fake PATH shims (assertions 1-3) ---
mkdir -p "$TMP/fakebin"
printf '#!/bin/bash\necho "hermes-test 99.0"\n' > "$TMP/fakebin/hermes"
printf '#!/bin/bash\necho "9router-test 99.0"\n' > "$TMP/fakebin/9router"
chmod +x "$TMP/fakebin"/*
export PATH="$TMP/fakebin:$PATH"

# --- fake HTTP servers: fixed-status responder (fake 9Router / fake tunnel URL) ---
serve() { # $1 = port, $2 = status code
  node -e "
const http = require('http');
http.createServer((req, res) => { res.writeHead($2); res.end('x'); }).listen($1, '127.0.0.1');
" >/dev/null 2>&1 &
}
PORT_R=18991  # fake 9Router dashboard
PORT_T=18992  # fake public tunnel URL (healthy)
PORT_502=18993 # fake public tunnel URL (502)
serve "$PORT_R" 200
serve "$PORT_T" 200
serve "$PORT_502" 502
sleep 1

# --- gateway: adopt the live one if exactly one exists, else fake it ---
# (never touch live infra; the test only READS the live gateway's pid)
EXISTING_GW="$(pgrep -f "$PATTERN" || true)"
if [ -z "$EXISTING_GW" ]; then
  # no live gateway: spawn a fake with the PROVISIONED argv shape (comma-separated).
  # NB: "python3 -I -c ..." here is only an argv[0] LABEL via exec -a; the
  # process actually exec'd is `sleep`. No python3 is executed or required.
  bash -c "exec -a \"python3 -I -c sys.argv = ['-c', 'gateway', 'run']\" sleep 600" &
  GW_PID=$!
elif [ "$(printf '%s\n' "$EXISTING_GW" | wc -l)" -eq 1 ]; then
  GW_PID="$EXISTING_GW"
else
  echo "SKIP: multiple gateway processes on this machine; gateway assertions untestable" >&2
  GW_PID=""
fi
sleep 0.5

# --- tunnel client: adopt the live one if any exists, else fake it ---
# (assertion 5 only needs >=1 pgrep match; never touch live infra.
#  Without this, the suite passes on the dev box only because the live
#  tunnel-client.mjs happens to be running — GitHub runners have none,
#  which is exactly how CI went red on 2026-10-01.)
if [ -z "$(pgrep -f "tunnel-client[.]mjs" || true)" ]; then
  # NB: argv[0] is only a LABEL via exec -a; the process exec'd is `sleep`.
  bash -c 'exec -a "node /fake/tunnel-client.mjs --test" sleep 600' &
fi
sleep 0.5

# --- fixture HERMES_HOME with a fresh heartbeat for the gateway pid ---
mkdir -p "$TMP/hermes/state"
fresh_iso() { node -e 'console.log(new Date().toISOString())'; }
if [ -n "$GW_PID" ]; then
  printf '{"pid": %s, "updated_at": "%s"}' "$GW_PID" "$(fresh_iso)" > "$TMP/hermes/state/gateway.heartbeat"
fi

# --- healthy config dir ---
mkdir -p "$TMP/healthy"
printf 'PLACEHOLDER=1\n' > "$TMP/healthy/.env"
printf 'http://127.0.0.1:%s\n' "$PORT_T" > "$TMP/healthy/.tunnel-url"  # trailing newline on purpose
printf 'placeholder\n' > "$TMP/healthy/.dashboard-pw"
chmod 600 "$TMP/healthy"/.env "$TMP/healthy"/.tunnel-url "$TMP/healthy"/.dashboard-pw

export HERMES_HOME="$TMP/hermes"
export DOCTOR_DIR="$TMP/healthy"
export DOCTOR_NINEROUTER_PORT="$PORT_R"

run_doctor() { bash "$DOCTOR" 2>&1; }  # low-level; prefer drun() below

# Capture output AND exit code safely under `set -e`.
# Usage: VAR=val drun   ->  $DOUT holds output, $DRC holds the exit code.
DOUT=""
DRC=0
drun() { DRC=0; DOUT="$(bash "$DOCTOR" 2>&1)" || DRC=$?; }

# --- T1: healthy stack -> canonical line ---
if [ -z "$GW_PID" ]; then
  echo "skip - T1 (multiple live gateways; canonical line untestable here)"
else
  drun
  if [ "$DRC" -eq 0 ] && printf '%s' "$DOUT" | grep -q "doctor: 11 ok, 0 FAIL, 0 warn, 1 skip"; then
    t_ok "healthy stack: 11 ok, 0 FAIL, 0 warn, 1 skip, exit 0"
  else
    t_fail "healthy stack (rc=$DRC): $(printf '%s' "$DOUT" | tail -1)"
  fi
fi

# --- T2: dead 9Router port -> assertion 4 FAIL, exit 1 ---
DOCTOR_NINEROUTER_PORT=9 drun
if [ "$DRC" -eq 1 ] \
  && printf '%s' "$DOUT" | grep -q "FAIL.*9Router dashboard not responding" \
  && printf '%s' "$DOUT" | grep -q "fix: bash restart-9router.sh"; then
  t_ok "dead 9Router port: assertion 4 FAIL -> restart-9router.sh, exit 1"
else
  t_fail "dead 9Router port (rc=$DRC)"
fi

# --- T3: unreachable tunnel URL -> warn (000 rule), exit still 0 ---
DOCTOR_TUNNEL_URL=http://127.0.0.1:9 drun
if [ "$DRC" -eq 0 ] && printf '%s' "$DOUT" | grep -q "\[warn\] cannot reach http://127.0.0.1:9"; then
  t_ok "unreachable tunnel URL: warn, exit 0"
else
  t_fail "unreachable tunnel URL (rc=$DRC)"
fi

# --- T4: hook precedence — hook URL (dead :9) wins over healthy file ---
DOCTOR_TUNNEL_URL=http://127.0.0.1:9 drun
if printf '%s' "$DOUT" | grep -q "cannot reach http://127.0.0.1:9"; then
  t_ok "DOCTOR_TUNNEL_URL wins over .tunnel-url file"
else
  t_fail "hook precedence"
fi

# --- T5: empty hook -> file wins (and trailing newline is trimmed) ---
DOCTOR_TUNNEL_URL= drun
if printf '%s' "$DOUT" | grep -q "\[ ok \] tunnel URL reachable (HTTP 200)"; then
  t_ok "empty hook: .tunnel-url file wins, trailing newline trimmed"
else
  t_fail "empty hook fallback"
fi

# --- T6a/b/c: heartbeat edges -> FAIL, script still reaches summary ---
printf '{"pid": %s, "updated_at": "2020-01-01T00:00:00.000Z"}' "${GW_PID:-0}" > "$TMP/hermes/state/gateway.heartbeat"
drun
if printf '%s' "$DOUT" | grep -q "FAIL.*heartbeat stale/unparseable" \
  && printf '%s' "$DOUT" | grep -q "^doctor:"; then
  t_ok "stale heartbeat -> FAIL, summary still printed"
else t_fail "stale heartbeat"; fi

printf '{"pid": %s}' "${GW_PID:-0}" > "$TMP/hermes/state/gateway.heartbeat"
drun
if printf '%s' "$DOUT" | grep -q "FAIL.*heartbeat stale/unparseable"; then
  t_ok "heartbeat missing updated_at -> FAIL"
else t_fail "heartbeat missing key"; fi

printf '{"pid": 1, "updated_at": "2026-' > "$TMP/hermes/state/gateway.heartbeat"
drun
if printf '%s' "$DOUT" | grep -q "FAIL.*heartbeat stale/unparseable" \
  && printf '%s' "$DOUT" | grep -q "^doctor:"; then
  t_ok "truncated heartbeat -> FAIL, no traceback, summary printed"
else t_fail "truncated heartbeat"; fi

printf '{"pid": 999999, "updated_at": "%s"}' "$(fresh_iso)" > "$TMP/hermes/state/gateway.heartbeat"
drun
if printf '%s' "$DOUT" | grep -q "FAIL.*heartbeat pid does not match"; then
  t_ok "heartbeat pid mismatch -> FAIL"
else t_fail "heartbeat pid mismatch"; fi

# restore fresh heartbeat for remaining tests
if [ -n "$GW_PID" ]; then
  printf '{"pid": %s, "updated_at": "%s"}' "$GW_PID" "$(fresh_iso)" > "$TMP/hermes/state/gateway.heartbeat"
fi

# --- T7: gateway pattern — shape coverage in node (mirrors the pgrep ERE) ---
PATTERN="$PATTERN" node -e '
  const re = new RegExp(process.env.PATTERN);
  const pos = [
    "/venv/bin/python -c \"...\" gateway run",                       // run-hermes.sh
    "hermes gateway run",                                            // normal install
    "python3 -I -c \"...sys.argv = ['"'"'-c'"'"', '"'"'gateway'"'"', '"'"'run'"'"']...\"" // provisioned
  ];
  const neg = [
    "bash gateway-watch.sh",
    "bash start-gateway.sh",
    "mygatewayrun tool",                                             // zero separator: must NOT match
    "pgrep -f \"[g]ateway['"'"'\", ]+run\""                            // the pattern text itself (bracket trick)
  ];
  let bad = 0;
  for (const s of pos) if (!re.test(s)) { console.error("MISS: " + s); bad++; }
  for (const s of neg) if (re.test(s))  { console.error("FALSE+: " + s); bad++; }
  process.exit(bad ? 1 : 0);
' >/dev/null 2>&1 && t_ok "gateway pattern: 3 shapes match, 4 negatives rejected" \
  || t_fail "gateway pattern shape coverage"

# --- T8: live pgrep — the gateway pid is found, decoys are excluded ---
# (decoys spawned after T1 so the canonical count is undisturbed)
bash -c 'exec -a "gateway-watch.sh check" sleep 600' & DECOY1=$!
bash -c 'exec -a "start-gateway.sh" sleep 600' & DECOY2=$!
bash -c 'exec -a "gatewayrun" sleep 600' & DECOY3=$!
sleep 0.5
FOUND="$(pgrep -f "$PATTERN" || true)"
decoy_hit=0
for d in "$DECOY1" "$DECOY2" "$DECOY3"; do
  if printf '%s\n' "$FOUND" | grep -q "^${d}$"; then decoy_hit=1; fi
done
if [ -n "$GW_PID" ] && printf '%s\n' "$FOUND" | grep -q "^${GW_PID}$" && [ "$decoy_hit" -eq 0 ]; then
  t_ok "live pgrep: gateway pid found, all 3 decoys excluded"
else
  t_fail "live pgrep decoy exclusion"
fi

# --- T9a: 502 + dead backend -> hint restart-9router.sh (acceptance b, branch 1) ---
DOCTOR_NINEROUTER_PORT=9 DOCTOR_TUNNEL_URL=http://127.0.0.1:$PORT_502 drun
if printf '%s' "$DOUT" | grep -q "FAIL.*HTTP 502.*fix: bash restart-9router.sh"; then
  t_ok "502 + dead backend: hint -> restart-9router.sh"
else t_fail "502 + dead backend hint"; fi

# --- T9b: 502 + healthy backend -> hint restart-tunnel.sh (acceptance b, branch 2) ---
DOCTOR_TUNNEL_URL=http://127.0.0.1:$PORT_502 drun
if printf '%s' "$DOUT" | grep -q "FAIL.*HTTP 502.*fix: bash restart-tunnel.sh"; then
  t_ok "502 + healthy backend: hint -> restart-tunnel.sh"
else t_fail "502 + healthy backend hint"; fi

# --- T10: cwd independence ---
if [ -z "$GW_PID" ]; then
  echo "skip - T10 (multiple live gateways)"
else
  cd /tmp && drun && cd "$SCRIPT_DIR" >/dev/null
  if printf '%s' "$DOUT" | grep -q "doctor: 11 ok, 0 FAIL, 0 warn, 1 skip"; then
    t_ok "cwd independence: same result from /tmp"
  else t_fail "cwd independence"; fi
fi

echo "----"
echo "doctor.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
