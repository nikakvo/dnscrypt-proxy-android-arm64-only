# Changelog

## v2.1.15-r1 — 2026-05-20

Script-only revision. No binary update.

### 🔒 QUIC Block *(new)*
Added iptables rule to block UDP port 443 (QUIC protocol) in `post-fs-data.sh`.
Chrome, YouTube and other Google apps use QUIC with built-in DoH that can bypass
dnscrypt-proxy DNS policies. Browsers auto-fallback to TLS/TCP transparently with
no user impact. Rule is cleanly removed on uninstall via `uninstall.sh`.

### 🔁 Watchdog — Port-Based Process Detection *(fix)*
Replaced unreliable `pgrep -x dnscrypt-proxy` with `ss` port check in `service.sh`.
`pgrep -x` in root shell context was matching the watchdog script itself (which
contains the binary path in its commands), causing a spurious restart loop and
`FATAL: bind: address already in use` errors in the log every 10 seconds.
Now checks `ss -ulnp / ss -tlnp` for `dnscrypt-proxy` on port 5354 instead.

### 📊 Status — Accurate Port-Based Health Check *(fix)*
Removed `nslookup` upstream health check from status reporting. `nslookup` is
a Termux binary not available in `/system/bin/`, causing the status to always
show `DNS Upstream Fail` even when the proxy was working perfectly. Status now
uses the same reliable `ss` port check as the watchdog.

---

## v2.1.15 — 2026-05-18

### 🔍 Conflict Detection & Auto-Removal *(new)*
Installer automatically detects conflicting DNS modules and apps before installation.
User is prompted via volume keys to remove them safely.

### ✅ Meta-Module Verification *(new)*
Installation aborts with clear instructions if no compatible meta-module is detected.

### 🔒 Boot-Time DNS Leak Prevention *(new)*
DNS is blocked at boot via iptables until dnscrypt-proxy is confirmed listening
on port 5354. The startup leak window is now closed.

### 📵 Full IPv6 Kill *(improved)*
IPv6 disabled at three levels simultaneously — Android system properties, kernel
sysctl and ip6tables DROP policy. Re-enforced every 60 seconds by the watchdog.

### 🔁 Self-Healing Watchdog *(improved)*
Watchdog uses `ss` with `netstat` fallback for port detection, 30-second startup
timeout with logging, and lifts the boot DNS block only after confirming
dnscrypt is ready.

### 🛡️ Hardened Resolver List *(improved)*
Removed servers with policy conflicts. Active list: Cloudflare, Quad9 (nofilter),
Mullvad Base DoH.

### ⚡ DNSCrypt-Proxy 2.1.15 Core *(upstream)*
- Dynamic timeout reduction under high load
- More accurate cache statistics
- Enhanced monitoring UI
- Fixed IPv6 DoH stamp double-bracketing bug
- Proxy hostname pre-resolution via bootstrap resolvers
