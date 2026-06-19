<p align="center">
  <img src="https://img.shields.io/badge/ARM64-only-green?style=flat-square" />
  <img src="https://img.shields.io/badge/dnscrypt--proxy-2.1.16-blue?style=flat-square" />
  <img src="https://img.shields.io/badge/KernelSU%20%2F%20SukiSU%20%2F%20Magisk-compatible-brightgreen?style=flat-square" />
</p>

<h1 align="center">DNSCrypt Proxy — Android ARM64</h1>
<p align="center">Full DNS privacy stack for Android · zero-leak design · ad/tracker blocking · live monitoring dashboard</p>

---

> **⚠ Aggressive module — read before installing.**
> This module kills IPv6, blocks QUIC, and enforces DNS at the kernel level.
> It is designed for maximum privacy and zero DNS leak tolerance. See [Known side effects](#known-side-effects) before proceeding.

---

## What It Does

Forces **all** DNS traffic on your device through an encrypted proxy, completely bypassing your ISP's DNS servers.

| Component | Description |
|---|---|
| **Encrypted DNS** | Runs `dnscrypt-proxy` 2.1.16 on `127.0.0.1:5354` |
| **iptables redirect** | Redirects all DNS traffic (port 53 → 5354) via NAT |
| **Boot DNS leak guard** | Blocks port 53 at early boot — DNS stays blocked until the proxy is confirmed ready |
| **IPv6 kill** | Disables IPv6 at 3 independent levels: `resetprop` + kernel `sysctl` + `ip6tables` DROP policy |
| **QUIC block** | Drops UDP port 443 — prevents Chrome/YouTube DoH bypass via QUIC |
| **Blocklist updater** | Action button downloads and merges OISD Big List with your existing blocklist |
| **Self-healing watchdog** | `service.sh` monitors `:5354` every 10s and restarts the daemon if needed |
| **Live dashboard** | Metrics API → `webroot/metrics.json`, viewable in `index.html` |

---

## DNS Flow

```
App DNS query
     │
     ▼
iptables NAT (port 53 → 5354)
     │
     ▼
dnscrypt-proxy (127.0.0.1:5354)
     │
     ├─ blocked?  → NXDOMAIN (from blocklist)
     │
     └─ allowed?  → encrypted upstream resolver
                          │
                    Cloudflare / Quad9 / Mullvad
                    (DNSCrypt or DoH, over TLS)
```

Your ISP sees only encrypted traffic — never your DNS queries.

---

## Requirements

| | |
|---|---|
| **Architecture** | ARM64 only |
| **Root manager** | SukiSU Ultra / KernelSU / Magisk |
| **Android** | 9+ |
| **Meta-module** | `magic_mount_rs` (recommended) · `hybrid_mount` · `meta-overlayfs` |

> A meta-module is **required**. The installer aborts if none is detected. Install one first, reboot, then flash this module.

---

## Installation

1. Install a compatible meta-module (`magic_mount_rs` recommended) and reboot
2. Flash `dnscrypt-proxy-android-arm64.zip` via SukiSU / KernelSU / Magisk
3. During install, use volume keys to respond to prompts:
   - **VOL UP** — Yes / Continue
   - **VOL DOWN** — No / Abort
4. If conflicting modules or apps are detected, the installer lists them and asks to remove them. Press **VOL UP** to confirm, then **reboot and flash again** — the second flash completes cleanly
5. Reboot

Config files are placed in `/storage/emulated/0/dnscrypt-proxy/` for easy access without a root file manager.

### Required: disable Private DNS

Android Private DNS must be **Off**. If enabled, Android sends DNS queries directly to the configured DoT server — bypassing dnscrypt-proxy completely. The installer disables it automatically, but verify it stays off.

- **Android 9–13:** Settings → Network & internet → Advanced → Private DNS → **Off**
- **Android 14+:** Settings → Network & internet → Private DNS → **Off**

### Required: disable Secure DNS in browsers

Browser-level DoH sends queries directly to the browser's resolver over HTTPS, bypassing dnscrypt-proxy and your blocklists.

- **Chrome:** Settings → Privacy and security → Security → Use secure DNS → **Off**
- **Firefox:** Settings → General → Network Settings → Enable DNS over HTTPS → **Off**
- **Brave:** Settings → Privacy and security → Security → Use secure DNS → **Off**

---

## Blocklist Updater (Action Button)

Tap the **▶ Action** button in your root manager to download and merge the latest [OISD Big List](https://big.oisd.nl).

**What it does:**
1. Downloads from OISD Big → hagezi pro.plus → hagezi ultimate (fallback chain)
2. Strips comments and empty lines
3. Merges with your existing `blocked-names.txt`, sorts, removes duplicates
4. Atomically replaces the blocklist and restarts `dnscrypt-proxy`

**Non-destructive:** your existing entries are always preserved. Running it multiple times is safe.

> The Action window may close before the final step completes — this is normal. The `sort | uniq` step on 500,000+ domains takes 30–60 seconds. The merge continues in the background and `dnscrypt-proxy` reloads the updated list automatically.

---

## Watchdog

A background loop runs every 10 seconds for the lifetime of the device session:

- **Process check** — verifies `dnscrypt-proxy` is listening on `:5354` (`ss` / `netstat` / `/proc/net/udp` fallback chain)
- **Auto-restart** — if not listening, starts the daemon and waits up to 90s for confirmation before lifting the DNS block
- **IPv6 re-enforcement** — re-applies all three IPv6 disable levels every ~60s (Android can restore IPv6 on network changes)
- **Status update** — writes `Working 🌬🌬🌬` or `Not Working 📵❌📵` to `module.prop`, visible in your root manager
- **Log rotation** — keeps the daemon log at 500 lines

---

## File Structure

```
dnscrypt-proxy-vX.X.X/
├── customize.sh          — installer: meta-module check, conflict detection, setup
├── post-fs-data.sh       — early boot: IPv6 kill, iptables DNS block
├── service.sh            — watchdog: starts proxy, enforces IPv6, updates status
├── action.sh             — blocklist updater (Action button)
├── uninstall.sh          — removes all rules, kills process, restores defaults
├── module.prop           — metadata, version, live status
├── binary/
│   └── dnscrypt-proxy-arm64    — upstream ARM64 binary
├── config/
│   ├── dnscrypt-proxy.toml     — main configuration
│   ├── blocked-names.txt       — domain blocklist
│   ├── blocked-ips.txt         — IP blocklist (CIDR supported)
│   ├── allowed-names.txt       — domain whitelist
│   ├── allowed-ips.txt         — IP whitelist
│   ├── public-resolvers.md     — resolver list
│   └── relays.md               — anonymized DNS relay list
└── webroot/
    ├── index.html              — monitoring dashboard
    └── help.html               — full documentation
```

After install, config is copied to `/storage/emulated/0/dnscrypt-proxy/`.  
**`blocked-names.txt` and `.bak` files are never overwritten on update** — your blocklist and config backups are preserved.

---

## Verify It Works

Open [dnsleaktest.com](https://dnsleaktest.com) and run the Extended Test.

Correct result: only your configured resolver (Cloudflare / Quad9 / Mullvad) should appear — **no ISP DNS servers**.

---

## VPN Combination

DNSCrypt works independently but pairs well with a WireGuard VPN for two independent protection layers.

> If using a WireGuard tunnel, **remove the `DNS =` line** from your `.conf` file. A tunnel-set DNS server will conflict with dnscrypt-proxy. With it removed, dnscrypt-proxy stays in full control.

---

## Known Side Effects

These are intentional design decisions, not bugs.

| Side effect | Cause | Impact |
|---|---|---|
| **VoWiFi / IMS may fail** | IPv6 kill | Some carriers (T-Mobile, Jio, Deutsche Telekom, some Greek operators) run VoWiFi over IPv6. Test carefully if WiFi calling matters to you. |
| **IPv6-only networks** | IPv6 kill | No internet on networks that are IPv6-only (rare, but exists in some enterprise/carrier configs). |
| **HTTP/3 not available** | QUIC block (UDP 443) | Sites fall back to HTTP/2 over TLS automatically. All major sites support this — no broken connections, marginally slower first connection only. |
| **Some P2P app features** | IPv6 kill | Apps that prefer IPv6 for peer-to-peer (some VoIP, gaming, video calls) may fall back to relay servers. |

> **If something breaks after installing this module — uninstall it first.** Remove via SukiSU / KernelSU / Magisk and reboot. If the problem goes away, the module is the cause. The uninstaller cleanly restores all iptables rules, IPv6 settings, and Private DNS to Android defaults.

---

## Conflicts

The installer **automatically detects and offers to remove** these before installation:

**Modules:** AdAway, BindHosts, Energized Protection, Systemless Hosts, DNS66, InviZible Pro, NextDNS, RethinkDNS, Cloudflared, SmartDNS, Dnsmasq, PersonalDNSfilter, Blokada  
**Apps:** AdGuard, Nebulo, ControlD  
**Processes:** dnsmasq, smartdns, cloudflared, adguard (if running)

---

## Uninstall

Remove via SukiSU / KernelSU / Magisk and reboot.

`uninstall.sh` automatically cleans up:
- Kills `dnscrypt-proxy`
- Removes all iptables NAT redirect rules (port 53 → 5354)
- Removes iptables DROP rules (port 53 + QUIC)
- Restores ip6tables to default ACCEPT policy
- Restores sysctl IPv6 settings
- Deletes Android properties set by `resetprop`
- Restores Android Private DNS to `opportunistic`
- Removes `/storage/emulated/0/dnscrypt-proxy/` and the log file

---

## What's New in v2.1.16

- ARM64 binary updated to dnscrypt-proxy 2.1.16 from official upstream source
- `tls_cipher_suite` removed from config — now a no-op in upstream, delete it from any old config
- QUIC iptables fix: missing `--reject-with` flag in `-D` rule in `post-fs-data.sh` caused the QUIC block rule not to be cleaned up properly on reload
- Watchdog port check now consistently uses `:5354` detection — avoids false positives
- `blocked-ips.txt` now supports full CIDR notation (e.g. `10.0.0.0/8`) in addition to single IPs
- Dashboard stats reset on every process restart — always shows current session data only
- Upstream: RTT recovery, stale cache fairness, HTTP/3 probing improvements, jsDelivr mirror added for resolver lists
- Upstream: relay name now included in log entries for anonymized DNS queries

---


<p align="center">
  Made by <a href="https://github.com/nikakvo">Tears Burn</a>
</p>
