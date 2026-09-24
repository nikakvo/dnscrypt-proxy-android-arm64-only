<p align="center">
  <img src="https://img.shields.io/badge/ARM64-only-green?style=flat-square" />
  <img src="https://img.shields.io/badge/v2.1.18--r13-blue?style=flat-square" />
  <img src="https://img.shields.io/badge/SukiSU%20%2F%20KernelSU%20%2F%20Magisk-compatible-brightgreen?style=flat-square" />
  <img src="https://img.shields.io/badge/WebUI-built%20in-00ff88?style=flat-square" />
</p>

# DNSCrypt-Proxy Android — arm64

Encrypted DNS for the whole device. Every app's DNS goes through [dnscrypt-proxy](https://github.com/DNSCrypt/dnscrypt-proxy), encrypted, to resolvers you choose — with ad and tracker blocking, leak protection from the first second of boot, and a WebUI that shows and controls everything.

<img width="300" alt="dnscrypt-proxy WebUI" src="https://raw.githubusercontent.com/nikakvo/dnscrypt-proxy-android-arm64-only/main/dnscrypt-proxy.jpg" />

---

## Features

- **Encrypted DNS for every app** — a transparent iptables redirect, nothing to configure per app
- **No leak window** — DNS is locked down at boot before the network is up; a leak guard drops anything that escapes
- **Blocklists** — OISD, HaGeZi, add-ons and your own URLs, merged and deduplicated; your custom list is always added on top
- **Tools** — check why a domain is blocked and by which list, allow or block with one tap
- **Resolvers** — pick from 700+ public resolvers, see what each one declares (no-log, filtering, DNSSEC), test latency
- **IPv4 / IPv6 modes** — strict IPv4, IPv6-compatible for IPv6-only carriers, or full dual stack — switchable live
- **Pause** — 5 / 15 / 60 minutes for hotel and airport Wi-Fi login pages
- **Self-healing** — a watchdog restarts a hung daemon, restores firewall rules Android removes, and never leaves the phone without internet

---

## How it works

```
App DNS request (port 53)
      ↓
iptables redirect → 127.0.0.1:5354
      ↓
dnscrypt-proxy: allow list → blocklist → cache
      ↓
encrypted (DoH / DNSCrypt) → Cloudflare · Quad9 · Mullvad
```

- Android's Private DNS is switched off at install (it would bypass the module) and restored on uninstall; if it gets switched on again, **System** offers a one-tap **Turn off**
- QUIC (UDP/443) is blocked by default so browsers cannot use their own built-in DoH
- Resolvers are pinned as signed stamps — the daemon starts with no download and no bootstrap DNS

---

## Requirements

| | |
|---|---|
| CPU | arm64 |
| Root | SukiSU Ultra or KernelSU (WebUI built in) · Magisk (WebUI via MMRL or KSU WebUI Standalone) |
| Android | 9+ |

---

## Installation

1. Flash `dnscrypt-proxy-vX.X.X.zip` in your root manager
2. The installer checks for conflicting DNS modules and apps (AdAway, RethinkDNS, NextDNS, Blokada, …)
   - found → it asks before removing them *(VOL UP = yes · VOL DOWN = abort)* → reboot and flash again
   - none → done in one flash
3. Reboot
4. Open the WebUI — the banner should say **Protected**

---

## WebUI

| Tab | What's there |
|---|---|
| **Dashboard** | Live stats, blocklist status, **Update Blocklist** with the source picker, cache, resolvers, top domains, recent queries. Tap any domain → Allow / Block / Check |
| **Tools** | **Check a domain** (verdict, matching rule, which list, live answer) · **My rules** (allow / block) · **Resolvers** |
| **System** | **Pause protection** · live status of every process, health check and firewall rule · **IP mode** · actions (restart, reload, reapply rules, run checks) · settings |
| **Log** | Module and dnscrypt-proxy log, filterable by level and source |

A full explanation of every section is in the WebUI under **Help**.

---

## Blocklists

Pick any combination under **Sources**:

| Group | Lists |
|---|---|
| OISD | Small · Big · NSFW Small · NSFW |
| HaGeZi | Light · Normal · Pro · Pro++ · Ultimate · Threat Intelligence mini / medium |
| Add-ons | Pop-up ads · Fake & scam · Gambling · NSFW · Xiaomi / Samsung / TikTok trackers · URL shorteners |
| Your own | any `https://` list — plain domains, hosts or AdBlock format |

On **Update** the selected lists are downloaded and verified, merged, deduplicated, subdomains already covered by a blocked parent are dropped, `custom-blocked-names.txt` is added on top, and dnscrypt-proxy reloads with no downtime.

- Each list is cached. If a download fails, its last good copy is used — a list never silently disappears
- **Automatic update**: off / daily / weekly, with the next run shown in the WebUI
- **Custom list**: `/sdcard/dnscrypt-proxy/custom-blocked-names.txt` — edits apply within a minute, deletions included, no download needed

Rule syntax:

```
example.com        example.com and all subdomains
=example.com       example.com only
ads.*              names starting with "ads."
*tracker*          names containing "tracker"
# comment
```

---

## IP modes

| Mode | IPv6 | IPv6 DNS | AAAA | For |
|---|---|---|---|---|
| **IPv4 only** (default) | off | — | blocked | strongest leak protection |
| **IPv6 compatible** | on | via the proxy | blocked | IPv6-only carriers (464XLAT) |
| **Dual stack** | on | via the proxy | answered | full IPv6 |

Switch in **System → IP Mode**, applied immediately. The IPv6 modes need IPv6 NAT in the kernel (`CONFIG_IP6_NF_NAT`); without it they run *limited* — IPv6 DNS is dropped instead of redirected, with no leak.

---

## Resolvers

Default: **Cloudflare · Quad9 · Mullvad** — none of them filter, the blocklists do that.

Change them in **Tools → Resolvers**. Protocol, logging, filtering and DNSSEC are decoded from each resolver's signed stamp in the official [public-resolvers](https://github.com/DNSCrypt/dnscrypt-resolvers) list. A new selection is checked by dnscrypt-proxy before it is used, and rolled back automatically if the daemon does not come up with it.

---

## Files

| Path | Purpose |
|---|---|
| `/data/adb/dnscrypt-proxy/` | Everything the daemon reads — config, lists, cached downloads |
| `/storage/emulated/0/dnscrypt-proxy/` | Editable copy — changes are picked up within a minute |
| `/data/adb/dnscrypt-proxy-android.conf` | Module settings (all changeable in the WebUI) |
| `/data/adb/dnscrypt-proxy.log` | Log |
| `http://127.0.0.1:5555` | dnscrypt-proxy's own monitoring page |

Settings, custom list, allow list, IP lists, chosen resolvers and cached blocklists are all kept across module updates.

---

## Command line

Everything the WebUI does is available from a root shell (e.g. Termux):

```sh
su -c sh /data/adb/modules/dnscrypt-proxy-android/ctl.sh status
```

| Command | |
|---|---|
| `status` · `probe` | full state · run the health checks now |
| `restart` · `reload` · `reapply-rules` | daemon and firewall actions |
| `check D` | is domain D blocked, by which rule and list |
| `allow D` · `unallow D` · `block D` · `unblock D` | your rules |
| `update start` · `sources-set A,B` | blocklists |
| `resolvers-set A,B` · `resolvers-test A,B` | resolvers |
| `ipmode-set ipv4\|compat\|dual` | IP mode |
| `pause MIN` · `resume` | pause protection |
| `private-dns-off` | switch Android Private DNS off |
| `log N` | last N log lines |

`ctl.sh help` lists everything.

---

## Verify

On **dnsleaktest.com** → Extended test:

- No entries from your ISP or carrier ✅
- Cloudflare / Quad9 / Mullvad (or your chosen resolvers) ✅
- No IPv6 address in IPv4-only mode ✅

---

## With a VPN

Works alongside WireGuard and other VPNs. Remove the `DNS =` line from the tunnel config so dnscrypt-proxy stays in charge — its encrypted queries then travel inside the tunnel.

Encrypted DNS hides *what you look up*; your carrier still sees which IP addresses you connect to. A VPN hides that. For apps that connect to hard-coded IP addresses and never use DNS, see the companion module **ipset-arm64**.

---

## Uninstall

Remove the module in your root manager and reboot. All firewall rules are removed, IPv6 and Android Private DNS are restored, and the module's files are deleted.

---

## Notes

- dnscrypt-proxy binary: built from upstream `main` (reports 2.1.19)
- Built and tested on a Poco F6 Pro with a [GKI KernelSU SUSFS](https://github.com/nikakvo/GKI_KernelSU_SUSFS) kernel, SukiSU Ultra and [Xiaomi.eu](https://xiaomi.eu/community/)
- Blocklists by [OISD](https://oisd.nl) and [HaGeZi](https://github.com/hagezi/dns-blocklists) · proxy by [DNSCrypt](https://github.com/DNSCrypt/dnscrypt-proxy)

---

*Maintained by Tears Burn · [GitHub](https://github.com/nikakvo)*
