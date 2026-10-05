# Clean-room install test

The one claim this repo makes that CI cannot verify: "an exact replica of
the stack, installable from scratch." This checklist is the procedure for
proving it on a fresh machine. Run it on a trial VPS (any provider with an
hourly-billed Ubuntu 22.04/24.04 image works; destroy the VM afterwards).

## Preparation

- Fresh Ubuntu 22.04 or 24.04, 2 vCPU / 4 GB RAM, no prior Hermuse install.
- A free Cloudflare account (for the tunnel leg).
- A Telegram bot from @BotFather + your numeric Telegram ID
  (from @userinfobot).

## Steps

Record the wall-clock time and the exact output of every `Verify:` line.
Anything that deviates from the README is a bug — file it, don't work
around it silently.

1. `git clone https://github.com/imkofty/Hermuse.git && cd Hermuse`
2. `bash scripts/install.sh`
   Verify: `hermes --version` and `9router --version` print version lines.
3. `hermes setup --portal` (model login) and `hermes gateway setup`
   (bot token + numeric-ID allowlist).
   Verify: send `/start` to the bot → it replies.
4. `bash scripts/setup-tunnel.sh <pages-project-name> <d1-name>`
   Verify: `pgrep -f "tunnel-client[.]mjs"` prints a PID.
5. Boot order from the README (9Router → tunnel → gateway), then
   `bash scripts/doctor.sh`.
   Verify: summary shows `0 FAIL`.
6. Open `https://<your-project>.pages.dev` in a browser.
   Verify: the 9Router dashboard appears (login redirect is normal).
7. Chat with the bot for 2–3 turns.
   Verify: replies arrive via the 9Router backend.
8. `bash scripts/doctor.test.sh`
   Verify: `14 passed, 0 failed`.

## Teardown

- `wrangler pages project delete <pages-project-name>` (or via dashboard).
- Delete the D1 database created in step 4.
- `/revoke` the test bot in @BotFather if it was throwaway.
- Destroy the VM.

## Reporting

Append a dated entry to `docs/clean-room-test.md` (this file): provider,
image, duration, and any deviation — even "worked exactly as documented"
is a useful data point.
