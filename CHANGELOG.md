# Changelog

All notable changes to `dnscrypt-proxy-android-arm64-only` are documented here.

---

### Added
- Web UI "Update Blocklist" button in `index.html` — triggers a blocklist update directly from the module's dashboard, with a live-scrolling log panel showing download/merge/dedupe progress and a final success/fail status.
- `busybox httpd` CGI control server on `127.0.0.1:5556`, started by `service.sh`, exposing:
  - `cgi-bin/update.sh` — starts the blocklist update (detached, survives Manager app close)
  - `cgi-bin/log.sh` — returns the last 80 lines of the update log
  - `cgi-bin/status.sh` — reports whether an update is currently running

### Changed
- `action.sh` renamed to `update-blocklist.sh`. It's no longer wired to a SukiSU/Magisk/KernelSU Action button — updates are now triggered exclusively from the Web UI.
- Blocklist reload after update now uses `pkill -HUP` instead of a full process kill. dnscrypt-proxy reloads its config/blocklist in place (supported since 2.1.13) instead of restarting, so the `:5555` metrics API never goes down and the dashboard no longer shows a stats blackout after every update.
- `uninstall.sh` now also kills the `busybox httpd` control server and any in-progress `update-blocklist.sh` run before removing files.

### Fixed
- `uninstall.sh` was deleting a log file named `dnscrypt-update.log`, which never existed — corrected to the actual filename, `dnscrypt-action.log`.

---

## v2.1.16-r1

### action.sh — Blocklist Updater
- **Fixed:** Progress bar no longer spams hundreds of lines — now prints every 5% only
- **Fixed:** OISD source URL updated from `domainswild` to `domainswild2` (current recommended format, ~700KB smaller, broader coverage)
- **Fixed:** Blocklist file size now reflects real content (~13MB with domainswild2 vs ~7MB before)
- **Fixed:** `EXPECTED` download size is now fetched dynamically via `Content-Length` header instead of hardcoded value — progress bar stays accurate regardless of list size
- **Improved:** Merge step now lowercases all domains before sort+uniq — prevents duplicate entries caused by mixed case
- **Improved:** `sort` fallback uses `-T /data/local/tmp` if default temp dir is not writable
- **Improved:** Lock file guard prevents double-runs; stale locks (>10 min) are cleaned automatically

### service.sh
- **Fixed:** Stale watchdog kill now uses `pgrep -f` instead of `ps -ef | awk '{print $1}'` — avoids wrong PID column on Android busybox builds
- **Improved:** Log rotation reduced from 500 to 300 lines
- **Added:** `blocklist_domains` field injected into `metrics.json` on every fetch cycle (live domain count from `blocked-names.txt`)

### customize.sh
- **Fixed:** `set_perm_recursive` now uses `0644` for files instead of `0755` — only shell scripts and the binary are explicitly set executable

### module.prop
- **Fixed:** `versionCode` corrected from `1` to `21116` — auto-update detection now works properly

### Dashboard (index.html)
- **Fixed:** NXDOMAIN stat no longer shows `—` — now counted from `nxdomain_queries` field or derived from `recent_queries` as fallback
- **Added:** NXDOMAIN percentage shown in Overview section
- **Added:** Blocklist section showing live domain count loaded from `blocklist_domains`

### uninstall.sh
- **Added:** Cleans up `dnscrypt-update.log` on uninstall
- **Added:** Comment clarifying that `.bak` backup files are removed intentionally on full uninstall

---

## 2.1.16 — Initial public release

### Added
- `dnscrypt-proxy` ARM64 binary deployment via systemless mount (`/system/bin/dnscrypt-proxy`)
- `post-fs-data.sh` — boot-time DNS leak prevention via iptables DROP on port 53
- `post-fs-data.sh` — full IPv6 disable: sysctl + resetprop + ip6tables DROP policy
- `post-fs-data.sh` — iptables NAT redirect: port 53 → `127.0.0.1:5354`
- `post-fs-data.sh` — QUIC block (UDP port 443) to prevent Chrome/YouTube DoH bypass
- `service.sh` — watchdog loop: monitors `:5354`, restarts daemon if not listening
- `service.sh` — CONFIG_WAIT guard: prevents double-start FATAL on storage unavailability
- `service.sh` — stale watchdog kill: terminates old instance on module update
- `service.sh` — IPv6 re-enforcement every ~60 seconds (Android may restore IPv6 on network change)
- `service.sh` — dynamic `Status:` update in `module.prop` (Working / Not Working)
- `service.sh` — `fetch_metrics`: pulls `/api/metrics` from daemon, writes `webroot/metrics.json` atomically
- `service.sh` — `ss` fallback chain: ss → netstat → `/proc/net/udp` hex check (port 0x14EA)
- `service.sh` — daemon log rotation: keeps last 500 lines
- `action.sh` — blocklist updater with progress bar and fallback sources (OISD Big → hagezi pro.plus → hagezi ultimate)
- `action.sh` — merge strategy: strip comments, combine with existing list, sort + dedup
- `action.sh` — atomic blocklist replace via `.new` temp file + flag file cleanup trap
- `action.sh` — automatic `dnscrypt-proxy` restart with watchdog handoff after update
- `customize.sh` — mount capability detection (capability flags → metamodule=1 → known IDs → legacy markers)
- `customize.sh` — conflict detection: modules (AdAway, Energized, SystemlessHosts, etc.), APKs (AdGuard, NextDNS, Nebulo, InviZible), processes (dnsmasq, cloudflared, smartdns)
- `customize.sh` — interactive conflict resolution with volume key confirmation
- `customize.sh` — safe config update: backup existing `.toml`, preserve `blocked-names.txt` and `.bak` files
- `customize.sh` — runtime binary verification (`-version` output check)
- `customize.sh` — Android 9+ Private DNS disable (`settings put global private_dns_mode off`)
- `uninstall.sh` — full cleanup: iptables, ip6tables, sysctl, resetprop, Private DNS restore, config dir removal
- `index.html` — built-in help page / dashboard
