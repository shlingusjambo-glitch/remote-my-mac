# Remote My Mac

Securely control your Mac from any modern browser (a Chromebook, a work PC) through **your own Cloudflare domain**.
Nothing is exposed to the internet except a Cloudflare Tunnel; the server only listens on `127.0.0.1`.

Licensed **GPL-3.0-or-later**.

## Features
- Live screen (hardware H.264 → WebCodecs), system **audio**, mouse, keyboard, scroll
- **Auto-scaling**: the Mac streams at the size of your browser window (never upscaled, ≤2560px), re-negotiated live on resize/fullscreen
- **Recovery**: browser auto-reconnects with a resume token (no password re-entry), capture restarts itself after display changes or errors, keyframe resync after packet backlog, held keys/buttons released on disconnect, LaunchAgent restarts the service if it crashes
- Chromebook-friendly: Ctrl→⌘ mapping toggle

## Security model
| Layer | What it does |
|---|---|
| Network | Binds `127.0.0.1` only. Reach it solely through `cloudflared`. No port forwarding, no open inbound ports. TLS is terminated by Cloudflare. |
| Cloudflare Access (recommended) | Put an Access policy (SSO / one-time email PIN / hardware key) in front of the hostname — attackers never even reach the login page. |
| Password | PBKDF2-HMAC-SHA512, 600,000 rounds, 32-byte random salt, constant-time compare, min 14 chars. (Chosen over bcrypt because it ships in macOS CommonCrypto — zero third-party code to audit; bcrypt/Argon2 would require a dependency. Use a long passphrase.) |
| 2FA | TOTP (RFC 6238) is generated at setup and required on every login, with replay protection. |
| Brute force | 5 failures → exponential per-IP lockout (30s doubling up to 1h) + global circuit breaker (40 failures/10 min → 15 min lock for everyone). Fixed ~0.6s response time; at most 2 concurrent hashes. |
| Web | Host allow-list, same-origin WebSocket check (anti-CSWSH), strict CSP, HSTS, no-store, frame denial. Pre-auth sockets die after 10s; only tiny frames accepted. |
| Sessions | One controller at a time (new login kicks the old). Resume tokens are 256-bit random, stored only as hashes, 15-min grace, 12h absolute. |
| Privacy | Screen is captured **only while a verified client is connected**. No telemetry, no third-party code. |
| Secrets | `config.json` is mode 600 in a 700 directory; password is never stored or logged. |

**Remember:** anyone who logs in controls your Mac as you. Use a unique passphrase, keep Cloudflare Access on, and enable FileVault + a lock screen.
Known limits: no end-to-end encryption beyond TLS-to-Cloudflare (Cloudflare can technically see traffic); keyboard mapping assumes US layout; single display (main).

### Pointer lock (Cloud gaming, browser games)

Games and streaming players grab the mouse with the Pointer Lock API. Most pass
`{unadjustedMovement: true}`, which on macOS switches Chromium to a raw-input path where injected
movement arrives as `movementX === 0` — the cursor is frozen even though scrolling and clicking still
work. No amount of OS-level injection can fix that, so the page has to be nudged back onto the
adjusted path; see [`extras/xcloud-lockfix`](extras/xcloud-lockfix) for the one-file extension that
does it (load unpacked, then reload the game tab).

## Install
```bash
./scripts/install.sh
```
Then follow the printed steps (`setup`, `permissions`, `launchctl bootstrap …`). In **System Settings → Privacy & Security** grant the binary
`~/Library/Application Support/RemoteMyMac/bin/remotemymac` both **Screen Recording** and **Accessibility** (use “+” if it isn't listed).

## Cloudflare Tunnel
```bash
brew install cloudflared
cloudflared tunnel login
cloudflared tunnel create remotemymac
cloudflared tunnel route dns remotemymac mac.example.com      # your hostname
```
`~/.cloudflared/config.yml`:
```yaml
tunnel: remotemymac
credentials-file: /Users/YOU/.cloudflared/<TUNNEL-ID>.json
ingress:
  - hostname: mac.example.com
    service: http://127.0.0.1:8777
  - service: http_status:404
```
```bash
sudo cloudflared service install      # or: cloudflared tunnel run remotemymac
```
Then in Cloudflare Zero Trust → Access → Applications, add a self-hosted app for `mac.example.com` with an allow policy for only you.
Open `https://mac.example.com` in Chrome/Edge.

## Commands
`remotemymac setup | permissions | run | passwd | totp-reset | totp-off`. Edit the web UI in `web/`, then run `scripts/embed-web.sh` and rebuild.

## Reporting vulnerabilities
See SECURITY.md.
