# Changelog

All notable changes to `dnscrypt-proxy-android-arm64-only` are documented here.

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
