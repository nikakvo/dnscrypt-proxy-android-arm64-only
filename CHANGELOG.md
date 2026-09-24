# Changelog

## 2.1.18-r14

* **Fixed: IPv6 was not used after leaving IPv4-only mode.** Switching to IPv6 compatible or Dual stack gave the phone its IPv6 addresses back within seconds, but Android kept seeing the network as IPv4-only until Wi-Fi or mobile data reconnected, so sites reported "IPv6 not detected". The module now checks this after the switch and, only if Android missed it, reconnects the network in use for a moment by itself - also under a VPN. Each decision is logged as "IPv6 refresh: …"
* New command `ctl.sh net-refresh-v6` for the same check by hand

## 2.1.18-r13

A bug-fix release. Every fix was reproduced first — on the phone or in a test harness that runs the module under both Android's own shell (mksh + toybox) and KernelSU's busybox — and verified after. Nothing to configure: settings, lists and resolvers carry over.

### dnscrypt-proxy

* Binary built from the current upstream `main` branch — it reports **2.1.19**, which is not yet a tagged release. The configuration format is unchanged
* 2.1.19 matches suffix rules only at label boundaries; the WebUI's **Check** already worked that way, so both now agree

### Fixed

* **Blocklist sources showed no rule count and no date.** Android's shell (mksh) treats `|` inside `${var%…}` as "or", so the `date|count` of every cached source came out empty. The WebUI now shows "N rules · date" for each source again
* **Reloads never reached dnscrypt-proxy from the watchdog.** KernelSU runs module scripts with its busybox, whose `pkill -x` compares against the daemon's full path and matched nothing — every list reload from the sdcard or a custom-list rebuild turned into a restart. Processes are now found by name in `/proc`, which works with every toolset and skips zombies. The installer had the same problem and could not stop the running daemon on an update
* **The WebUI stayed blank while DNS was down.** The Google font was loaded with an `@import` that held back the page's script until the request finished — with no DNS, until it timed out. The font now loads in the background; the page works instantly with or without it
* **The watchdog could hang forever without busybox.** Android's own `nc` only uses `-w` for connecting, so a UDP health check never returned. The right option is now picked per tool, with `timeout` as a second guard
* **Firewall repair put rules in the wrong order.** When Android removed only part of the redirect, the missing rule went back above the bootstrap exemptions, which then never matched. Exemptions are now re-seated on top whenever the redirect is repaired
* **Pause left a partial redirect in place.** While paused, any leftover rule is now removed, not only a complete set
* **A restart could be reported as done before the daemon was back.** A finished DNS-over-TCP connection on port 5354 counted as "listening"; only real listeners count now
* **An update could look finished right after it started**, and the WebUI stopped following it. The start is now marked until the update has taken over. Stopping an update now really stops it, including its downloads, and releases its lock
* **A failed custom-list rebuild was reported as applied.** Removing the last custom rule with no source selected is now possible (the result is an empty list), and a list from before r13 no longer trips the "list would shrink" guard
* **Updating the module erased `allowed-ips.txt` and `blocked-ips.txt`.** Both are now kept like the other lists
* **Uninstall could switch Android Private DNS on** for someone who had it off. The original setting is now recorded at the first install, whatever it was, and restored exactly
* A `dnscrypt-proxy.toml` from the sdcard with the other IP mode's listener (for example `[::1]` in IPv4 mode) no longer keeps the daemon from starting
* Error text from a process that exited mid-check could end up in the WebUI's data
* The watchdog's health-check count missed queries sent while the daemon was starting, which inflated Total slightly

### Faster

* **Restart, IP mode switch and new resolvers**: back in ~1–3 s instead of up to 15 — the WebUI now wakes the watchdog instead of waiting for its next 10-second tick
* **"Starting…" after a restart** now lasts about as long as dnscrypt-proxy actually needs (2–3 s) instead of ~10 s more
* **Check a domain** answers in well under a second instead of 3–6 s

### WebUI

* New **Starting…** banner while dnscrypt-proxy is fetching its resolvers' certificates, instead of a false "Nothing resolves"
* **One action at a time**: while a command runs, other buttons are dimmed and ignored — including taps made while the screen was busy, which Android used to deliver all at once afterwards (switching IP mode several times in a row, each one restarting the daemon)
* **Android Private DNS**: when it is on (it goes around the module), System shows a **Turn off** button. Also `ctl.sh private-dns-off`
* "Last Snapshot" is shown in the phone's time instead of UTC
* The banner no longer shows "0 total · 0 blocked" while dnscrypt-proxy's statistics are not available yet
* Every action reports a failure or timeout instead of leaving the page half-updated
* Help updated

## 2.1.18-r12

The biggest release so far: a new WebUI, blocklist sources, IPv6 support, domain tools, resolver choice and a rebuilt core. Settings, custom lists and cached data carry over from earlier versions automatically.

### Resolvers

* Updated `public-resolvers.md` and `relays.md` to the current signed lists (521 → 776 resolvers). Several stamps had changed since the shipped copy, including Quad9's, which now declares DNSSEC
* Default resolvers are now Cloudflare, Quad9 and **Mullvad (non-filtering)**. The previous default, `mullvad-base-doh`, filters ads and trackers by itself - redundant next to the blocklists. Anyone still on the old default is moved over; a selection you made yourself is kept, with refreshed stamps
* Checked against dnscrypt-proxy 2.1.19 (not yet released): its configuration is unchanged, so the module will take the new binary without changes

### WebUI

* Rebuilt on the root manager's own `ksu.exec` bridge. The busybox HTTP server on `127.0.0.1:5556` is gone - it had no authentication, and any app on the phone could reach it
* Four tabs: **Dashboard**, **Tools**, **System**, **Log**
* A status banner that says what is actually going on: Protected, Nothing resolves, Not responding, Paused, Failsafe
* **System** shows every process with its PID and uptime, both health checks, every firewall rule and kernel feature, each as a live check
* Actions: Restart daemon, Reload lists, Reapply rules, Run checks
* Settings are switches that apply immediately - no more editing a file and rebooting
* **Log** viewer with level and source filters
* Tapping any domain on the dashboard offers Allow, Block and Check
* Every button shows it was pressed, pulses while its command runs, and ignores repeated taps; a thin bar under the header shows the phone is working
* The watchdog's own health-check queries are subtracted from the statistics and hidden from the lists
* "?" became **Help**, rewritten to explain every section and function

### Blocklists

* Choose any combination of sources: OISD (Small, Big, NSFW Small, NSFW), HaGeZi (Light to Ultimate, Threat Intelligence), add-ons (pop-up ads, scams, gambling, NSFW, Xiaomi / Samsung / TikTok trackers, URL shorteners) and your own URLs in plain, hosts or AdBlock format
* Lists are merged, deduplicated, and subdomains already covered by a blocked parent are removed; `custom-blocked-names.txt` is always added on top
* Every source is cached. A failed download falls back to its last good copy instead of silently dropping out of the list; each source shows updated / cached / failed
* Automatic update: off, daily or weekly, with the next run shown
* Editing the custom list rebuilds the blocklist from the cache within a minute - no download, and deleted lines are really removed
* Custom rules are kept exactly as written. The old `*.` prefixing broke `=exact` rules and turned `ads.*` into a match on everything containing "ads."
* The blocklist count no longer includes comment lines, and the error-page check on downloads now works with Android's grep

### Tools

* **Check a domain**: verdict, the exact rule that matches (including a blocking parent), which list it came from, and the live answer from dnscrypt-proxy
* **My rules**: allow and block lists with one-tap removal, applied immediately
* **Resolvers**: 16 well-known resolvers plus a search of all 700+, with protocol, logging, filtering and DNSSEC decoded from each signed stamp, a latency test, and a configuration check before applying - with automatic rollback if dnscrypt-proxy does not come up

### IPv4 / IPv6

* New **IP mode**: IPv4 only (default, as before), IPv6 compatible (for IPv6-only / 464XLAT carriers), Dual stack
* In the IPv6 modes, IPv6 DNS is redirected into the proxy as well; the kernel's IPv6 NAT support is detected, and without it the modes run "limited" with IPv6 DNS dropped rather than leaked
* Switching is immediate, without a reboot
* Replaces `IPV6_KILL` and the self-lifting `IPV6_AUTO_LIFT` heuristic; old settings are migrated

### Pause protection

* Pause for 5, 15 or 60 minutes for Wi-Fi login pages, with a countdown and Resume. Ends by itself, and after any reboot

### Reliability

* **Health checks**: a local liveness query every 30 s restarts a daemon that holds its port but stopped answering (at most 5 times in 15 minutes); a real lookup every 60 s tells "working" from "no upstream"
* **Reloads are confirmed**: after a SIGHUP the module waits for dnscrypt-proxy to acknowledge it, and restarts it if it does not
* The failsafe no longer fires on an intentional restart, which opened a few seconds of plaintext DNS on every restart
* A daemon that is running but cannot reach upstream stays fail-closed instead of briefly dropping the redirect
* A crash loop (e.g. a broken config) retries once a minute instead of every 10 seconds
* All intervals use time since boot. A wrong clock at boot showed a 20,718-day uptime and could postpone the failsafe indefinitely
* The sdcard mirror now works: `mtime_of` and `seed_sdcard` were called but never defined, so edits made on the sdcard were never copied in
* Health-check probes only trust a netcat that supports UDP and has answered before, so a limited busybox can never trigger a false "hung"
* Blocklist rebuilds are locked against each other and refuse a result that would halve the list when the sources have not changed

### Under the hood

* New structure: `sh/common.sh`, `sh/rules.sh`, `sh/blocklist.sh`, `sh/tools.sh`, `sh/resolvers.sh`, and `ctl.sh` - a command-line interface for everything the WebUI does
* The watchdog no longer fetches metrics or polls the screen state; the WebUI reads them only while it is open
* The settings file is parsed instead of executed: only known keys with plain values are accepted
* Updates keep your allow list and chosen resolvers (both used to be reset by every flash)
* Consistent log format with levels

### Upgrade notes

* Flash over the previous version and reboot. The first blocklist update downloads your sources into the new cache; until then the previous list stays in use
* The WebUI needs SukiSU / KernelSU, or MMRL / KSU WebUI Standalone on Magisk. The module itself works without it
* Private DNS, IPv6 and firewall handling are unchanged in the default IPv4 mode

---

## 2.1.18-r11.6

Fixes the long-standing problem where a reboot or flashing another module left the device with no DNS until this module was reflashed.

### Startup

* Pinned the three configured resolvers as `[static]` stamps and disabled the remote source lists, so the daemon starts with no source download, no bootstrap DNS and no network at all
* Set `netprobe_timeout = 0`, which was costing a guaranteed 60-second stall on every boot because the probe was aimed at a port-53 address this module redirects into dnscrypt-proxy itself
* Moved the config, resolver cache and blocklist from `/storage/emulated/0` to `/data/adb/dnscrypt-proxy`, ending the race with the FUSE storage stack that left the redirect installed with no daemon behind it
* Added a sdcard mirror at `/storage/emulated/0/dnscrypt-proxy` that syncs editable files inward on change, restarting the daemon for a config edit and reloading it for a list edit
* Killed any leftover dnscrypt-proxy at startup, so a module update no longer leaves the previous binary holding `:5354`
* Cut the failsafe grace period from 180 to 90 seconds
* Added a config check at flash time, so a broken toml is reported during install instead of black-holing DNS until the failsafe fires

### DNS rules

* Removed the boot-time port-53 DROP rule, which could never match because nat OUTPUT rewrites the port before filter OUTPUT sees the packet
* Added a real leak guard scoped to non-loopback output, catching port-53 traffic that escaped the redirect
* Exempted only root-owned traffic to the three bootstrap resolvers rather than all of uid 0, so the module's own `curl` still resolves through the proxy
* Switched rule installation from `-A` to `-I OUTPUT 1` so the redirect sits above netd's rules
* Re-verified the rules every tick against a sentinel from nat, filter and ip6tables, instead of only inside a branch that required the daemon to already be listening
* Extended the QUIC block to IPv6, which was previously unblocked the moment the IPv6 killswitch lifted
* Extracted all iptables rules into `rules.sh`, shared by `post-fs-data.sh`, `service.sh` and `uninstall.sh`

### IPv6

* The killswitch no longer lifts itself on a heuristic; auto-lift is opt-in via `IPV6_AUTO_LIFT` and off by default
* Made enforcement idempotent, so it no longer rewrites sysctls, calls `resetprop` and rebuilds loopback rules every 60 seconds when nothing has changed
* Left per-interface `disable_ipv6` alone by default, since forcing it is an endless tug-of-war with the modem's rmnet contexts and the ip6tables DROP policy already guarantees what it was meant to; `IPV6_PER_IFACE_ENFORCE` restores the old behaviour

### Health check

* Replaced the `-resolve` check, which ran a second dnscrypt-proxy against the same cache files and could corrupt the `public-resolvers.md` / `.minisig` pair into a state only a reflash could clear
* The probe now sends a raw DNS query straight to `127.0.0.1:5354`, needing no resolver tool and no NAT redirect
* The monitoring-API liveness check no longer overrules a failed DNS probe; it is used only on a device with no way to ask a DNS question

### Blocklist

* A changed `custom-blocked-names.txt` is merged into the live blocklist within a minute, deletions included, instead of waiting for a full re-download

### Logging and cost

* Fixed rotation writing to an unlinked inode, which left the new log empty and never reclaimed the space
* Moved rotation onto a timer, since it previously only ran when starting the daemon and a healthy device never reached that branch
* Raised the budget to 1500 lines, configurable via `LOG_KEEP_LINES`
* Cached the blocklist line count instead of running `grep -cv` over a 7.6 MB file every 10 seconds
* Dropped `dumpsys power` polling from every tick to once a minute

### Uninstall and install

* `private_dns_mode` is restored to its pre-install value instead of always being set to `opportunistic`
* Fixed the `getevent` handler leaking a process after the conflict prompt
* New settings are appended to an existing settings file on upgrade rather than overwriting it
