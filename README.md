<p align="center">
  <img src="https://img.shields.io/badge/ARM64-only-green?style=flat-square" />
  <img src="https://img.shields.io/badge/dnscrypt--proxy-2.1.16-blue?style=flat-square" />
  <img src="https://img.shields.io/badge/KernelSU%20%2F%20SukiSU%20%2F%20Magisk-compatible-brightgreen?style=flat-square" />
</p>

# DNSCrypt-Proxy Android — arm64

### by Tears Burn | v2.1.16 | SUkiSU Ultra · KernelSU · Magisk

Encrypts all DNS traffic on your device. No ISP snooping. No DNS hijacking. No ads.

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

- ISP sees **encrypted traffic only**
- Android Private DNS disabled on install to prevent bypass
- IPv6 killed at three levels — system properties, sysctl, ip6tables
- DNS blocked at boot until proxy is confirmed ready — zero startup leak window
- Self-healing watchdog — restarts dnscrypt-proxy automatically if it crashes
- IPv6 re-enforcement every ~60 seconds

---

## Requirements

- arm64 device
- SUkiSU Ultra / KernelSU / Magisk with root
- Android 9+

---

## Installation

1. Flash `dnscrypt-proxy-vX.X.X.zip` via SUkiSU / KernelSU / Magisk
2. The installer automatically:
   - Scans for conflicting DNS modules and apps
   - Prompts to remove conflicts if found *(VOL UP = yes / VOL DOWN = abort)*
   - If conflicts removed: **reboot and flash again**
   - If no conflicts: installation completes in one flash
3. Reboot

Module status should show `Working 🌬🌬🌬` in your manager.

---

## DNS Resolvers

| Resolver | Type | No-Log | DNSSEC | Location |
|---|---|---|---|---|
| Cloudflare | DoH | ✅ | ✅ | Global anycast |
| Quad9 (nofilter) | DoH | ✅ | ✅ | Switzerland 🇨🇭 |
| Mullvad Base | DoH | ✅ | ✅ | Sweden 🇸🇪 |

Load balanced automatically — fastest one wins.

---

## Configuration

| Path | Purpose |
|---|---|
| `/storage/emulated/0/dnscrypt-proxy/dnscrypt-proxy.toml` | Config file |
| `/data/adb/dnscrypt-proxy.log` | Log file |
| `http://127.0.0.1:5555` | Monitoring dashboard |
| `http://127.0.0.1:5556` → Update Blocklist | Blocklist updater |

Config supports hot-reload — edit blocklists or resolver settings without reboot (`SIGHUP`).

On update, existing config is backed up with a timestamp before replacement.

---

## Conflict Detection

The installer auto-detects and removes conflicting modules and apps — you will be prompted before anything is removed.

**Modules:** BindHosts, AdAway, Energized, Systemless Hosts, DNS66, InviZible Pro, NextDNS, RethinkDNS, Cloudflared, SmartDNS, Dnsmasq, AdGuard, PersonalDNSfilter, Blokada, Nebulo, ControlD

**Apps:** org.adaway, org.blokada, dnsfilter.android, com.frostnerd.smokescreen, com.controld.app, com.nextdns.nextdns, com.celzero.bravedns, com.rethinkdns.rethink and others

---

## WireGuard / VPN

Works alongside ProtonVPN WireGuard and other VPN clients.

If your VPN config has a `DNS =` line — remove it. DNSCrypt must remain in control of DNS or the two will conflict.

---

## Verify

Run an extended test on **dnsleaktest.com** after install:

- No entries from your ISP ✅
- Cloudflare / Quad9 / Mullvad visible ✅
- No IPv6 address showing ✅

---

## Uninstall

Remove via SUkiSU / KernelSU / Magisk and reboot. The uninstaller removes all iptables rules, restores IPv6 and Android Private DNS to defaults, and cleans up config and logs.

---

*Maintained by Tears Burn · [GitHub](https://github.com/nikakvo)*
