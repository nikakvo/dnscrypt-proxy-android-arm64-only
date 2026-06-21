<p align="center">
  <img src="https://img.shields.io/badge/ARM64-only-green?style=flat-square" />
  <img src="https://img.shields.io/badge/dnscrypt--proxy-2.1.16-blue?style=flat-square" />
  <img src="https://img.shields.io/badge/KernelSU%20%2F%20SukiSU%20%2F%20Magisk-compatible-brightgreen?style=flat-square" />
</p>

# DNSCrypt-Proxy Android — arm64

### by Tears Burn | v2.1.16-r3 | SUkiSU Ultra · KernelSU · Magisk

---

## What is this?

An **always up-to-date arm64 module** that forces all DNS traffic on your device through an encrypted proxy — completely bypassing your ISP's DNS servers.

No ISP snooping. No DNS hijacking. No tracking. No ads.

> **Always current.** Every time a new dnscrypt-proxy release drops upstream, the binary and the module are updated. You are never running an outdated or abandoned build.

---

## Why this module over everything else?

Most DNS privacy tools for Android are either abandoned, broken on newer root implementations, or rely on VPN slots that conflict with actual VPNs. This module does none of that.

| Feature | This Module | InviZible Pro | AdAway | NextDNS Module |
|---|---|---|---|---|
| Self-built binary (latest upstream) | ✅ Always | ❌ Bundled | ❌ N/A | ❌ Bundled |
| No VPN slot used | ✅ | ❌ Uses VPN | ✅ | ❌ Uses VPN |
| Boot-time DNS leak prevention | ✅ | ❌ | ❌ | ❌ |
| IPv6 killed at 3 levels | ✅ | ⚠️ Partial | ❌ | ❌ |
| Self-healing watchdog | ✅ | ❌ | ❌ | ❌ |
| Conflict detection & auto-removal | ✅ | ❌ | ❌ | ❌ |
| SUkiSU Ultra / KernelSU / Magisk | ✅ All three | ⚠️ Partial | ⚠️ Partial | ⚠️ Partial |
| Works alongside ProtonVPN WireGuard | ✅ | ❌ Conflicts | ✅ | ❌ Conflicts |

---

## ⚠️ Read Before Installing

This is an **aggressive module with strict rules**. The following are intentional design decisions — not bugs.

- **IPv6 is fully killed** at three independent levels simultaneously (system properties, kernel sysctl, ip6tables DROP). The watchdog re-enforces this every ~60 seconds. If VoWiFi / IMS on your carrier requires IPv6, test carefully.
- **QUIC is blocked** (UDP port 443). Chrome, YouTube and other Google apps use QUIC with built-in DoH that bypasses dnscrypt-proxy. Blocking QUIC forces them back to TLS where the DNS redirect rules apply. Browsers fall back automatically.
- **Private DNS must be OFF.** The installer disables it automatically, but verify it stays off: `Settings → Network & internet → Private DNS → Off`
- **Browser Secure DNS must be OFF** in every browser (Chrome, Firefox, Brave, Samsung Internet). Browser-level DoH sends DNS directly to external resolvers over HTTPS, bypassing everything.
- **`blocked-names.txt` is replaced on every update** — not merged with the old file. Your personal domains go in `gustum-blocked-names.txt` and are always preserved across updates.

> If something breaks after installing — uninstall via your root manager and reboot. The uninstaller cleanly restores all iptables rules, IPv6 settings, and Private DNS to Android defaults.

---

## How it works

```
App DNS request
      ↓
iptables redirect (port 53 → 127.0.0.1:5354)
      ↓
dnscrypt-proxy (encrypted + authenticated)
      ↓
Cloudflare / Quad9 / Mullvad  ← fastest resolver wins
```

- ISP sees **encrypted traffic only** — not your DNS queries
- Private DNS (Android 9+) is disabled on install to prevent bypass
- IPv6 is killed at three simultaneous levels — system properties, kernel sysctl, ip6tables DROP policy
- DNS is fully blocked at boot until the proxy is confirmed ready — zero startup leak window
- Watchdog re-enforces IPv6 kill every ~60 seconds
- Self-healing: if the proxy crashes, the watchdog detects it and restarts it automatically — DNS stays blocked via iptables during the restart window, no leaks

---

## DNS Resolvers

Three resolvers across three jurisdictions. Load balanced automatically — fastest one wins.

| Resolver | Type | No-Log | DNSSEC | Location |
|---|---|---|---|---|
| Cloudflare | DoH | ✅ | ✅ | Global anycast |
| Quad9 (nofilter) | DoH | ✅ | ✅ | Switzerland 🇨🇭 |
| Mullvad Base | DoH | ✅ | ✅ | Sweden 🇸🇪 |

All three have publicly available privacy policies and have passed independent audits. Quad9 is a nonprofit organization. The `nofilter` variant of Quad9 is used deliberately — ad/tracker blocking is handled by the local blocklists, not by the resolver.

---

## Blocklist

The module ships with a pre-built `blocked-names.txt` from the [OISD Big List](https://oisd.nl) — one of the most comprehensive and actively maintained blocklists available, covering ads, trackers, malware, phishing, telemetry, and coinminers. All entries use wildcard format (`*.domain.com`) to block entire subdomains with a single rule.

### gustum-blocked-names.txt — your personal blocklist

A dedicated file for domains you want blocked permanently, independent of the OISD list:

```
/storage/emulated/0/dnscrypt-proxy/gustum-blocked-names.txt
```

- One domain per line. Wildcard prefix (`*.`) is supported and recommended.
- **Survives every update** — on each update run, your entries are automatically appended to the fresh OISD download before the final deduplication step.
- Comments (`#`) and blank lines are stripped automatically.
- If the file is empty or absent, the updater continues normally with no impact.

```
# gustum-blocked-names.txt example
*.facebook.com
*.instagram.com
*.tiktok.com
*.telemetry.example.com
```

### If a site or app stops working

With 800,000+ domains in the blocklist, occasional false positives happen. To fix:

1. Ask Claude or ChatGPT: *"What domains does [app/site] use?"*
2. Search for those domains in `/storage/emulated/0/dnscrypt-proxy/blocked-names.txt` or `gustum-blocked-names.txt`
3. Remove the matching lines — hot-reload applies the change instantly, no reboot needed
4. For permanent exceptions, add the domain to `allowed-names.txt` — whitelisted domains are never blocked even if they appear in the blocklist

---

## Blocklist Updater

The monitoring dashboard includes a one-tap blocklist updater. It downloads a fresh copy of the OISD Big List, merges it with your `gustum-blocked-names.txt`, deduplicates the result, and reloads dnscrypt-proxy — no reboot required.

**How to use:**
1. Open the dashboard at `http://127.0.0.1:5556`
2. Scroll to **Update Blocklist** and tap **⬇ Update blocked-names.txt**
3. The button locks immediately — do not tap again while it is running
4. The entire dashboard auto-refresh pauses until the update completes
5. When done, the log clears, the button unlocks, and the new blocklist loads automatically

**What it does under the hood:**
1. Downloads the latest OISD Big List with a live progress bar (falls back to hagezi pro.plus → hagezi ultimate if OISD is unreachable)
2. Strips comments and blank lines; adds `*.` wildcard prefix to any domain that does not already have one
3. Concatenates the cleaned download with your `gustum-blocked-names.txt` and pipes through `sort | uniq`
4. Atomically replaces `blocked-names.txt` and sends `SIGHUP` to the running daemon — zero DNS downtime

The **Latest Update** timestamp in the dashboard Blocklist section shows the exact date and time of the last successful update.

---

## Monitoring Dashboard

A built-in web dashboard is served locally at:

```
http://127.0.0.1:5556
```

Open it in any browser on the device. It shows live metrics fetched directly from the dnscrypt-proxy API every 10 seconds: total queries, blocked queries, block rate, cache hit ratio, average RTT, uptime, resolver health, and blocklist domain count with last update timestamp.

> The dashboard is served by busybox httpd on loopback only — not accessible from outside the device.

---

## Requirements

- arm64 device only
- SUkiSU Ultra / KernelSU / Magisk with root
- Android 9+
- One of the following **meta-modules installed first:**

| Meta-Module | Download |
|---|---|
| magic_mount_rs *(Recommended)* | [github.com/Tools-cx-app/meta-magic_mount-rs](https://github.com/Tools-cx-app/meta-magic_mount-rs/releases) |
| hybrid_mount | [github.com/Hybrid-Mount/meta-hybrid_mount](https://github.com/Hybrid-Mount/meta-hybrid_mount/releases) |
| meta-overlayfs | [github.com/KernelSU-Modules-Repo/meta-overlayfs](https://github.com/KernelSU-Modules-Repo/meta-overlayfs/releases) |

> **The installer will abort if no meta-module is detected. Install one first, reboot, then flash this module.**

---

## Installation

1. Install a compatible meta-module (see above)
2. Reboot your device
3. Flash `dnscrypt-proxy-vX.X.X.zip` via SUkiSU / KernelSU / Magisk
4. The installer automatically:
   - Verifies meta-module is present
   - Scans for conflicting DNS modules and apps
   - Prompts you to remove conflicts if found *(VOL UP = yes / VOL DOWN = abort)*
   - If conflicts were removed: reboot and flash again
   - If no conflicts: installation completes in one flash
5. Reboot

Module status in your root manager should show `Working 🌬🌬🌬`

<img width="300" alt="dnscrypt" src="https://raw.githubusercontent.com/nikakvo/dnscrypt-proxy-android-arm64-only/main/dnscrypt.jpg" />

---

## Conflict Detection

The installer automatically detects and removes the following if found:

**Conflicting modules:** BindHosts, AdAway, Energized Protection, Systemless Hosts, DNS66, InviZible Pro, NextDNS, RethinkDNS, Cloudflared, SmartDNS, Dnsmasq, AdGuard, PersonalDNSfilter, Blokada, Nebulo, ControlD

**Conflicting apps:** org.adaway, org.blokada, dnsfilter.android, com.frostnerd.smokescreen, com.controld.app, com.nextdns.nextdns, com.celzero.bravedns, com.rethinkdns.rethink and others

> You will be asked before anything is removed. VOL UP to confirm, VOL DOWN to abort.

---

## The full privacy stack — DNSCrypt + ProtonVPN WireGuard

DNSCrypt alone is already a major upgrade. Combined with **ProtonVPN WireGuard tunnels**, you get two independent protection layers that cover each other's blind spots.

| Protection | VPN Only | DNSCrypt Only | VPN + DNSCrypt |
|---|---|---|---|
| ISP can see visited websites | ✅ Hidden | ✅ Hidden | ✅ Hidden |
| ISP can see your real IP | ✅ Hidden | ❌ Visible | ✅ Hidden |
| DNS requests encrypted | ❌ Depends | ✅ Always | ✅ Always |
| DNS leak protection | ❌ Risky | ✅ | ✅ Full |
| Ad & tracker blocking | ❌ | ✅ | ✅ |
| IPv6 leak protection | ❌ | ✅ | ✅ Full |
| Works without VPN active | ❌ | ✅ | ✅ |

### Real data flow with both active

```
Your Device
     │
     ▼
DNSCrypt Proxy (port 5354)
 • Encrypts DNS requests
 • Blocks ads and trackers
 • Eliminates IPv6 leak vectors
     │
     ▼
WireGuard Tunnel (ProtonVPN)
 • Encrypts all traffic
 • Hides your real IP
 • Exits through ProtonVPN servers (NL / CH / CA...)
     │
     ▼
  Internet
(Websites only see the ProtonVPN IP — your ISP sees only encrypted noise)
```

### Setup with WireGuard

1. Install **WireGuard** from the Play Store
2. Import your `.conf` tunnel files (Add tunnel → Import from file)
3. **Remove the `DNS =` line** from each tunnel config — DNSCrypt handles DNS and the two must not conflict
4. Connect to your preferred server

---

## Configuration

All user-facing config lives on internal storage — no root file manager needed:

```
/storage/emulated/0/dnscrypt-proxy/
├── dnscrypt-proxy.toml        ← main config
├── blocked-names.txt          ← domain blocklist (replaced on every update)
├── gustum-blocked-names.txt   ← your personal domains (never touched by updater)
├── blocked-ips.txt            ← IP blocklist
├── allowed-names.txt          ← domain whitelist
├── allowed-ips.txt            ← IP whitelist
└── query.log                  ← live query log
```

Daemon log (errors, restarts, watchdog events):

```
/data/adb/dnscrypt-proxy.log
```

Hot-reload is supported — changes to blocklist files and most config settings take effect without a reboot.

---

## Verify It Works

Open **dnsleaktest.com** and run the Extended Test.

A correct result:
- No entries from your ISP (Cosmote, Wind, Vodafone, etc.) ✅
- You see Cloudflare, Quad9, or Mullvad entries ✅
- No IPv6 address visible anywhere ✅

---

## Frequently Asked Questions

**Will my internet become slower?**
Only minimally. DNSCrypt adds ~30–50ms to DNS requests on average. Once a domain is cached — effectively zero delay. WireGuard is the fastest VPN protocol available and adds negligible overhead.

**⚠️ First Boot — Expected Delay**
On first boot or after switching networks (enabling VPN, switching between WiFi and mobile data), you may notice 5–10 seconds before DNS resolves normally. DNSCrypt-Proxy benchmarks all three resolvers and picks the fastest one. Once cached, subsequent connections are instant.

**Does DNSCrypt work without a VPN?**
Yes, completely independently. The VPN is an optional second layer. DNSCrypt alone already eliminates ISP DNS surveillance and blocks ads at the network level.

**What happens if dnscrypt-proxy crashes?**
The self-healing watchdog detects the failure and restarts it automatically. DNS remains blocked via iptables until the proxy is confirmed listening again — no traffic leaks to your ISP during the restart window.

**Is it safe?**
The binary is built directly from the official [dnscrypt-proxy](https://github.com/DNSCrypt/dnscrypt-proxy) upstream source. No patches, no modifications to the core. Resolvers used — Cloudflare, Quad9, Mullvad — all have public no-log policies and independent audits.

**A site or app stopped working after installing.**
It is most likely blocked by the blocklist. Ask Claude or ChatGPT what domains the app uses, search for them in `blocked-names.txt`, and remove the matching lines. Or add the domain to `allowed-names.txt` for a permanent whitelist exception.

**Will this work with my current VPN?**
If your VPN uses a VPN slot (OpenVPN, IKEv2, most commercial apps) — yes, no conflict. If it uses WireGuard — remove the `DNS =` line from the tunnel config so DNSCrypt stays in control of DNS.

---

## Uninstall

Remove the module via SUkiSU / KernelSU / Magisk and reboot. The uninstaller automatically:

- Kills the dnscrypt-proxy process
- Removes all iptables and ip6tables rules
- Restores IPv6 to default
- Restores Android Private DNS to default (opportunistic)
- Removes config directory and log file

---

## Notes

- Module status updates every 10 seconds in your module manager
- On first install, config is written fresh. Existing config is backed up with a timestamp
- IPv6 re-enforcement every ~60 seconds is intentional — some system events can restore IPv6 temporarily
- The monitoring dashboard (`http://127.0.0.1:5556`) is loopback-only and serves only while the module is active
- Built and tested against the Poco F6 Pro SukiSU kernel setup and SukiSU Ultra Manager used in this repository: [poco-f6-pro-sukisu-kernel-archive](https://github.com/nikakvo/poco-f6-pro-sukisu-kernel-archive) and [Xiaomi.eu ROM](https://xiaomi.eu/community/)

---

*Maintained by Tears Burn · [GitHub](https://github.com/nikakvo)*
