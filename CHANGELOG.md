# Changelog

---

## [2.1.16] - 2026-05-24

### 🔄 DNSCrypt-Proxy upstream (2.1.16)
- Servers with temporarily high RTT now recover automatically and re-enter rotation — previously they could stay penalized forever
- Servers are no longer penalized for slow responses when the reply is served from stale cache — fairer load balancing with `wp2`
- `blocked-ips.txt` now officially supports full CIDR notation (e.g. `10.0.0.0/8`) in addition to prefix wildcards
- Dashboard HTML pages are no longer cached — fixes stale UI after upgrades
- `jsdelivr` added as additional mirror for resolver lists — more reliable startup fetching
- HTTP/3 probing now uses a negative cache to avoid repeated probes against servers known not to support it
- HTTP transport handles `Alt-Svc: clear` correctly and reuses connections more aggressively
- Log entries now include the relay name when a query was sent through an anonymized DNS or ODoH relay
- ODoH: 401 key-refresh path hardened against panics and races
- `tls_cipher_suite` option is now a no-op — modern TLS stacks no longer expose cipher suite selection; option removed from config
- New `tls_prefer_rsa` option available for systems without hardware AES (not needed on ARM64 with hardware AES)
- `miekg/dns` library updated to v2 series
- `-resolve` command now correctly reports incomplete DNSSEC support instead of treating partial signatures as success

### 🛠️ Module changes
- Updated binary to dnscrypt-proxy `2.1.16` arm64
- Removed `tls_cipher_suite = [52392]` from `dnscrypt-proxy.toml` — option is now a no-op upstream
- Fixed QUIC iptables rule in `post-fs-data.sh` — `--reject-with` flag was missing from `-D` causing the old rule to not be properly cleaned up on reload
- Fixed watchdog loop in `service.sh` to check `:5354` port instead of process name — consistent with startup `READY` check and more reliable
- Fixed status check in `service.sh` to use `:5354` port — avoids false positives if a process named `dnscrypt-proxy` exists but is not listening
- Updated `blocked-ips.txt` with additional rebind protection ranges: link-local (`169.254.*`), full CGNAT range (`100.64-127.*`), documentation ranges (`192.0.2.*`, `198.51.100.*`, `203.0.113.*`), reserved ranges (`240-255.*`), and full IPv6 rebind protection (`::1`, `::`, `fc*`, `fd*`, `fe80*`, `2001:db8*`, `fec-fef*`)

---

## Version v2.1.15-r4

### Updated
- Updated dnscrypt-proxy to latest upstream build

### Fixed
- Added upstream fix for malformed DNS responses
- Improved validation of DNS reply question sections
- Better handling of invalid/malformed DNS packets
- Increased stability and parser safety in response pipeline

### Security
- Hardened DNS response validation against malformed packets

## v2.1.15-r3 — 2026-05-23

### 🖥️ Webroot UI — full redesign *(new)*

- `index.html` replaces the built-in dnscrypt-proxy dashboard at `127.0.0.1:5555`
- Scrollable dashboard with 6 sections: Overview, Result Distribution, Resolvers, Query Types, Top Domains, Recent Queries
- Live status banner with pulsing dot indicator
- Built-in music player with visualizer bars, volume control and session restore across navigation
- Quick-access buttons: DNS Test, Ads Test, Ads Test 2, My IP
- Query log trimmed to 2000 lines for webroot copy — reduced I/O with no meaningful data loss
- Original dnscrypt-proxy UI remains accessible directly at `http://127.0.0.1:5555`

## v2.1.15-r2 (2026-05-21)

### Binary update
- Upstream dnscrypt-proxy `4f151a5` — **xtransport: improve HTTP connection reuse**
  - `MaxIdleConns` raised from 1 → 16: multi-resolver setups no longer re-handshake on every server rotation
  - `IdleConnTimeout` decoupled from keepalive knob and fixed at 90 seconds — connections stay warm regardless of keepalive config
  - HTTP/3 (QUIC) transport now correctly drains idle connections on rebuild, same as HTTP/2
  - SNI fix for DoH stamps that connect via IP with a different cert name — TLS/QUIC no longer overrides SNI incorrectly

### Module fix
- `service.sh` — `lift_dns_block()` now uses `iptables -C` before `-D`; rules are only removed when they actually exist. Eliminates silent no-op iptables calls on every 10-second watchdog tick when the boot block is already gone.

---

## v2.1.15-r1 — 2026-05-21

Script-only revision. No binary update.

### 🔒 QUIC Block *(new)*
Added iptables rule to block UDP port 443 (QUIC protocol) in `post-fs-data.sh`.
Chrome, YouTube and other Google apps use QUIC with built-in DoH that can bypass
dnscrypt-proxy DNS policies. Browsers auto-fallback to TLS/TCP transparently with
no user impact. Rule uses `-C` check to prevent duplicates on reload.
Cleanly removed on uninstall via `uninstall.sh`.

### 🔁 Watchdog — Port-Based Process Detection *(fix)*
Replaced unreliable `pgrep -x dnscrypt-proxy` with `ss` port check in `service.sh`.
`pgrep -x` in root shell context was matching the watchdog script itself,
causing a spurious restart loop and `FATAL: bind: address already in use`
errors in the log every 10 seconds.

### 🛡️ Watchdog — Duplicate iptables Prevention *(fix)*
All `iptables -A` rules in `post-fs-data.sh` now use `-C || -A` pattern.
Rules are only added if they don't already exist, preventing duplicates
on module reload or kernel network events.

### 📊 Status — Accurate Health Check *(fix)*
Removed `nslookup` upstream check. `nslookup` is a Termux binary not available
in `/system/bin/`, causing status to always show `DNS Upstream Fail` even when
everything was working. Status now uses reliable `ss` port check.

### ✍️ Status — Reduced Filesystem Writes *(fix)*
`module.prop` is now only rewritten when status actually changes.
Previously `sed -i` ran every 10 seconds regardless, causing unnecessary
writes to the `/data` partition.

### ⚡ Watchdog — CPU Priority *(new)*
Added `renice -n 10` at startup of `service.sh`. The watchdog now runs
at low CPU priority and does not compete with foreground apps.

### 🔍 SELinux Logging *(new)*
Added SELinux detection at watchdog startup. If SELinux is Enforcing,
an INFO entry is written to the log to aid debugging on custom ROMs.

### 🔧 ss Fallback to netstat *(new)*
Added automatic fallback: if `ss` is not available on the ROM,
the watchdog transparently uses `netstat` instead. Improves compatibility
with stripped-down or older Android builds.

### 🛠️ Installer — Safe getevent Cleanup *(fix)*
Replaced `pkill -f "getevent"` with `pkill -P $$` in `customize.sh`.
The old command could accidentally kill unrelated getevent processes
(e.g. an active Termux session). Now only child processes of the
installer itself are terminated.

---

## v2.1.15 — 2026-05-18

### 🔍 Conflict Detection & Auto-Removal *(new)*
Installer automatically detects conflicting DNS modules and apps before
installation. User is prompted via volume keys to remove them safely.

### ✅ Meta-Module Verification *(new)*
Installation aborts with clear instructions if no compatible meta-module
is detected.

### 🔒 Boot-Time DNS Leak Prevention *(new)*
DNS is blocked at boot via iptables until dnscrypt-proxy is confirmed
listening on port 5354. The startup leak window is now closed.

### 📵 Full IPv6 Kill *(new)*
IPv6 disabled at three levels simultaneously — Android system properties,
kernel sysctl and ip6tables DROP policy. Re-enforced every 60 seconds
by the watchdog to survive network events.

### 🔁 Self-Healing Watchdog *(new)*
Watchdog monitors the proxy and restarts it if it dies. Uses `ss` with
`netstat` fallback for port detection. 30-second startup timeout with
full logging.

### 🛡️ Hardened Resolver List *(new)*
Three no-log, DNSSEC-validating resolvers across three jurisdictions:
Cloudflare (DoH), Quad9 nofilter (DNSCrypt), Mullvad Base (DoH).
Fastest one is selected automatically.

### ⚡ DNSCrypt-Proxy 2.1.15 *(upstream)*
- Dynamic timeout reduction under high load
- More accurate cache statistics
- Enhanced monitoring UI
- Fixed IPv6 DoH stamp double-bracketing bug
- Proxy hostname pre-resolution via bootstrap resolvers
