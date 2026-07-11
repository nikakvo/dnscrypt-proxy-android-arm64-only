# Changelog

All notable changes to `dnscrypt-proxy-android-arm64-only` are documented here.

---

## 2.1.16-r8

Updated to latest upstream dnscrypt-proxy binary.

Upstream changes: DNS cache is now initialized once at plugin init
(no more lazy init via sync.Once), simplifying cache setup and
removing an unused sync dependency. Internal refactor only — no
config or behavior changes for end users.

---

## 2.1.16-r7 — 2026-07-07

### Fixed
- **Critical: DNS could be permanently black-holed if dnscrypt-proxy failed to start in time.**
  The boot-time failsafe (`force_lift_dns_block_failsafe`, fires ~180s after boot if
  dnscrypt-proxy isn't confirmed listening + resolving) only removed the `OUTPUT DROP`
  rule on port 53. It never removed the `nat OUTPUT` DNAT rule redirecting all DNS
  traffic to `127.0.0.1:5354`. If dnscrypt-proxy genuinely never came up, "lifting the
  block" didn't restore DNS — it just changed an explicit block into a silent
  black hole (DNS packets NATed to a dead local port, no response, no error).
  To the user this was indistinguishable from "no internet," and it did not
  self-heal on reboot, because whatever kept dnscrypt-proxy from starting
  (e.g. stale/corrupted resolver cache on external storage) persisted across
  reboots too. Only a full reflash — which resets `public-resolvers.md`,
  `relays.md`, `allowed-*.txt`, `blocked-ips.txt` in `customize.sh` — happened
  to clear the underlying cause and mask the real bug.

### Added
- `remove_dns_nat_redirect()` in `service.sh` — removes the port-53 DNAT
  redirect. Called from the failsafe path so "lifting the block" actually
  restores working (plaintext, temporarily) DNS instead of a black hole.
- `restore_dns_nat_redirect()` in `service.sh` — re-adds the DNAT redirect if
  dnscrypt-proxy catches up *after* the failsafe already fired, so DNS gets
  routed back through the proxy again instead of staying in plaintext forever.

### Changed
- Watchdog catch-up check in the main loop now verifies both the DROP rule
  *and* the NAT redirect state (not just the DROP rule), and restores
  whichever is missing once `is_resolving()` confirms dnscrypt-proxy is
  actually serving queries.

### Binary
- Refreshed arm64 `dnscrypt-proxy` binary to the latest upstream build
  (pulled 2026-07-07). No functional dependency changes relevant to this
  module — the only pending upstream change on that date
  ([DNSCrypt/dnscrypt-proxy#3265](https://github.com/DNSCrypt/dnscrypt-proxy/pull/3265))
  is an **unmerged** dependabot bump of `kardianos/service` (Windows/systemd
  service-registration library), which isn't used on Android at all. Binary
  refresh is a routine sync, not a fix carried in with this release.

### Testing notes
- Verified over 3 consecutive boots (1 reflash + 2 clean reboots) on device:
  dnscrypt-proxy came up and confirmed resolving within 60–70s each time,
  well under the 180s failsafe threshold. No FAILSAFE/FATAL/ERROR entries
  logged. The actual failsafe/NAT-restore code path has not yet been
  triggered live since the fix was applied — logs from a future occurrence
  (if any) should be checked for the new `restoring NAT redirect` log line
  to confirm the fix engages correctly.

---

## v2.1.16-r6

### Fixed
- **Permanent internet loss after reboot.** Under certain boot conditions (slow network bring-up, storage mounting late), `service.sh`'s watchdog could get stuck in a restart loop for 20+ minutes — `dnscrypt-proxy` would bind port `:5354` and immediately get treated as "ready," but then stall trying to fetch its resolver/source lists over HTTPS, give up, and restart from scratch. The DNS-block-until-ready safeguard in `post-fs-data.sh` had no way to recover from this on its own, leaving the device with no DNS at all until the module was manually reflashed.

### Changed
- **Real resolution check instead of port-only check.** The watchdog no longer lifts the boot-time DNS block just because `dnscrypt-proxy` is listening on `:5354`. It now also verifies the daemon can actually answer a query (`dnscrypt-proxy -resolve example.com`, using the existing config and binary — no extra process competing for the port) before unblocking traffic. If it's listening but not yet resolving, the watchdog keeps retrying on every tick instead of forcing a full restart, so it recovers as soon as the daemon catches up.
- **Hardened stale-watchdog cleanup.** Previously relied solely on `pgrep -f`, which isn't guaranteed on every ROM/busybox build. Now falls back to scanning `/proc/*/cmdline` directly if `pgrep` is unavailable or returns nothing, preventing a leftover watchdog from a previous boot from racing the new one for port `:5354`.

### Added
- **Boot grace-period failsafe (3 minutes).** If `dnscrypt-proxy` still isn't up and resolving after a generous boot grace period — for any reason (storage never mounted, binary won't bind, crash-looping, etc.) — the DNS block is force-lifted so the device falls back to working (unencrypted) internet instead of staying stuck offline indefinitely. This only ever triggers well outside the normal startup window and never weakens the leak-prevention behavior during a healthy boot; it's purely a last-resort recovery path. A clear `FAILSAFE` line is written to `/data/adb/dnscrypt-proxy.log` whenever this fires, so it's obvious when it happened and that something needs investigating.

### Notes
- No changes to `customize.sh`, `post-fs-data.sh`, the `.toml` config, or `webroot/index.html` — only `service.sh` was touched.
- If you ever see `WARNING - dnscrypt-proxy listening but not resolving after 60s` once or twice right after boot on a slow network, that's expected and should self-resolve within a tick or two. Repeated `FAILSAFE` lines across multiple reboots would indicate something else is wrong and worth investigating (network readiness, bootstrap resolvers, etc).

---

## What's New in v2.1.16-r5

* Updated to latest upstream dnscrypt-proxy build
* Added Post-Quantum DNSCrypt (PQDNSCrypt) support
* Added CIRCL cryptography backend
* Improved DoH3 / HTTP3 reliability
* Automatic retry for temporary HTTP/3 failures
* Fixed cloaking cycle detection
* Fixed origin resolution issues
* Upstream optimizations and bug fixes

Full credit goes to the upstream dnscrypt-proxy project. This module packages the latest arm64 build for Android.


## v2.1.16-r4 — 2026-06-20

## What's New

* Updated to the latest dnscrypt-proxy upstream binary.
* Added improved support for Post-Quantum DNSCrypt (X-Wing) certificate retrieval.
* Enhanced compatibility with anonymized DNSCrypt relays.
* Improved handling of large DNSCrypt certificate responses over UDP.
* Includes all upstream stability, reliability and performance improvements.

## Fixed

* Fixed scenarios where Post-Quantum certificates could fail to be discovered through certain relay configurations.
* Improved certificate probing behavior for large encrypted DNS responses.

## Upgrade Notes

* No user action required.
* Existing configuration files remain fully compatible.
* Simply install the updated module version.


## v2.1.16-r3 — 2026-06-20

Dashboard (index.html)
Blocklist Updater — button lock during update

The ⬇ Update blocked-names.txt button now disables itself immediately on tap and shows ⏳ Updating… — cannot be tapped a second time while the operation is running
The top banner switches to amber ⚙ Running command — blocklist update in progress… for the duration of the update
All navigation buttons (DNS Test, Ads Test, My IP, Help) are locked during update — navigating away and returning no longer causes the UI to show a false "ready" state while the command is still running
The auto-refresh cycle (every 10s) is fully paused while an update is in progress — no partial renders, no state resets
The output log clears automatically 5 seconds after the update completes
After completion, loadData() resumes normally and the dashboard returns to its live state

Blocklist — Latest Update timestamp

The Blocklist section now shows a Latest Update row with the exact date and time of the last successful blocked-names.txt update
Timestamp is written by update-blocklist.sh at the moment of successful atomic replacement and read by status.sh on every poll — not derived from file mtime

update-blocklist.sh
gustum-blocked-names.txt support

Introduced gustum-blocked-names.txt — a user-owned personal blocklist file located in /storage/emulated/0/dnscrypt-proxy/
On every update: fresh OISD download + gustum-blocked-names.txt are concatenated and passed through a single sort | uniq — the result replaces blocked-names.txt
The old blocked-names.txt is no longer merged — every update starts clean from the fresh download
If gustum-blocked-names.txt is absent or empty, the updater continues normally with no changes to behavior
Comments (#) and blank lines in gustum-blocked-names.txt are stripped automatically

Wildcard prefix enforcement

All domains in the downloaded list that do not already carry a *. prefix now receive one automatically via sed after the clean step
Ensures consistent wildcard blocking across the entire list regardless of source format

Timestamp on success

On successful atomic replace, the exact timestamp is written to /storage/emulated/0/dnscrypt-proxy/.last_update
Used by status.sh to expose last_update in the CGI response

cgi-bin/status.sh

Now returns last_update field alongside running in the JSON response
Reads from .last_update file written by update-blocklist.sh — accurate to the second, not dependent on filesystem mtime

help.html

Warning section updated: replaced "Blocklist accumulates" notice with accurate description of the new replace-not-merge behavior and gustum-blocked-names.txt survivability guarantee; added "A site or app stopped working" guidance with instructions to ask Claude/GPT for domain lists and search both blocklist files
Config Location updated: gustum-blocked-names.txt added to the directory tree with description
Blocklist Updater section fully rewritten: documents the dashboard button workflow, the lock/pause mechanism, gustum-blocked-names.txt usage with example, step-by-step update flow reflecting the new logic, and "If a site or app stops working" troubleshooting guide
File Structure section updated: full tree reflecting current layout including cgi-bin/ contents, update-blocklist.sh, gustum-blocked-names.txt, and META-INF/
Blocklist Updater added to sidebar navigation (was missing)

---

### v2.1.16-r2 Added
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
