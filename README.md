# DNSCrypt-Proxy Android — arm64

### by Tears Burn | v2.1.15-r1 | SUkiSU Ultra · KernelSU · Magisk

---

## What is this?

A self-built arm64 module that forces **all DNS traffic** on your device
through an encrypted proxy, completely bypassing your ISP's DNS servers.
No DNS snooping, no hijacking, no tracking.

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

> **The installer will abort if no meta-module is detected.**
> **Install one first, reboot, then flash this module.**

---

## Installation

1. Install a compatible meta-module (see above)
2. Reboot your device
3. Flash `dnscrypt-proxy-vX.X.X.zip` via SUkiSU / KernelSU / Magisk
4. The installer will automatically:
   - Verify meta-module is present
   - Scan for conflicting DNS modules and apps
   - Prompt you via volume keys to remove conflicts if found
   - *(VOL UP = yes / VOL DOWN = abort)*
   - If conflicts were removed → reboot and flash again
   - If no conflicts → installation completes in one flash
5. Reboot

---

## ⚠️ First Boot — Expected Delay

On first boot or after switching networks (enabling VPN, switching
between WiFi and mobile data), you may notice **5–10 seconds** before
DNS resolves normally.

This is expected. DNSCrypt-Proxy benchmarks all three resolvers and
picks the fastest one. Once cached, subsequent connections are instant.

---

## Conflict Detection

The installer automatically detects and offers to remove:

**Conflicting modules:** AdAway, BindHosts, Energized Protection,
Systemless Hosts, DNS66, InviZible Pro, NextDNS, RethinkDNS,
Cloudflared, SmartDNS, Dnsmasq, AdGuard, PersonalDNSfilter,
Blokada, Nebulo, ControlD

**Conflicting apps:** org.adaway, org.blokada, dnsfilter.android,
com.frostnerd.smokescreen, com.controld.app, com.nextdns.nextdns,
com.celzero.bravedns, com.rethinkdns.rethink and others

> You will always be asked before anything is removed.

---

## How It Works

```
App DNS request
      ↓
iptables redirect (port 53 → 127.0.0.1:5354)
      ↓
dnscrypt-proxy (encrypted + authenticated)
      ↓
Cloudflare DoH / Quad9 DNSCrypt / Mullvad DoH
(fastest server wins, auto load-balanced)
```

- ISP sees **encrypted traffic only** — not your DNS queries
- Android Private DNS (DoT) is disabled on install
- **IPv6 fully killed** at three levels — props, sysctl, ip6tables
- **QUIC blocked** (UDP 443) — prevents DoH bypass via Chrome/YouTube
- **Boot DNS leak prevention** — DNS blocked until proxy is ready
- **Self-healing watchdog** — proxy auto-restarts if it crashes
- **ss fallback** — uses netstat on ROMs without ss

---

## DNS Resolvers

| Resolver | Protocol | No-Log | DNSSEC | Location |
|---|---|---|---|---|
| Cloudflare | DoH | ✅ | ✅ | Global anycast |
| Quad9 nofilter | DNSCrypt | ✅ | ✅ | Switzerland |
| Mullvad Base | DoH | ✅ | ✅ | Sweden |

Three different jurisdictions, three different operators.
Fastest one selected automatically via weighted latency balancing.

---

## Configuration

Config file:
```
/storage/emulated/0/dnscrypt-proxy/dnscrypt-proxy.toml
```

Hot-reload supported — edit blocklists or resolver settings without reboot.

Monitoring dashboard (browser):
```
http://127.0.0.1:5555
```

Log file:
```
/data/adb/dnscrypt-proxy.log
```

---

## Status

Module status updates in your module manager every 10 seconds:

| Status | Meaning |
|---|---|
| `Init` | Module just loaded, proxy starting |
| `Working 🌬🌬🌬` | Proxy running, port 5354 active |
| `Not Working 📵❌📵` | Proxy not responding |

---

## Uninstall

Remove the module via SUkiSU / KernelSU / Magisk and reboot.
The uninstaller automatically:
- Kills the dnscrypt-proxy process
- Removes all iptables rules (DNS redirect, DROP, QUIC block)
- Removes all ip6tables rules
- Restores IPv6 to system default
- Restores Android Private DNS to default (opportunistic)
- Removes config directory and log file

---

## Notes

- On first install, config is written fresh. Existing config is backed up with a timestamp
- IPv6 re-enforcement runs every ~60 seconds — intentional, Android can re-enable it on network events
- QUIC block may affect UDP-based gaming on port 443. Disable by removing the rule from `post-fs-data.sh` if needed
- Module is arm64 only — will abort on other architectures

---

*Built and maintained by Tears Burn*
