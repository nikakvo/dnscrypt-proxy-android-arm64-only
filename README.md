# DNSCrypt-Proxy Android — arm64

### by Tears Burn | v2.1.15 | SUkiSU Ultra · KernelSU · Magisk

---

## What is this?

**always up-to-date** arm64 module that forces all DNS traffic on your device through an encrypted proxy — completely bypassing your ISP's DNS servers.

No ISP snooping. No DNS hijacking. No tracking. No ads.

> **Always current.** Every time a new dnscrypt-proxy release drops upstream, the binary is rebuilt and the module is updated. You are never running an outdated or abandoned build.

---

## Why this module over everything else?

Most DNS privacy tools for Android are either abandoned, broken on newer root implementations, or rely on VPN slots that conflict with actual VPNs. This module does none of that.

| Feature | This Module | InviZible Pro | AdAway | NextDNS Module |
|---|---|---|---|---|
| Self-built binary (latest upstream) | ✅ Always | ❌ Bundled | ❌ N/A | ❌ Bundled |
| No VPN slot used | ✅ | ❌ Uses VPN | ✅ | ❌ Uses VPN |
| Boot-time DNS leak prevention | ✅ | ❌ | ❌ | ❌ |
| IPv6 killed at 3 levels | ✅ | ❌ Partial | ❌ | ❌ |
| Self-healing watchdog | ✅ | ❌ | ❌ | ❌ |
| Conflict detection & auto-removal | ✅ | ❌ | ❌ | ❌ |
| SUkiSU Ultra / KernelSU / Magisk | ✅ All three | ⚠️ Partial | ⚠️ Partial | ⚠️ Partial |
| Works alongside ProtonVPN WireGuard | ✅ | ❌ Conflicts | ✅ | ❌ Conflicts |

---

## The full privacy stack — DNSCrypt + ProtonVPN WireGuard

DNSCrypt alone is already a major upgrade. But combined with **ProtonVPN WireGuard tunnels**, you get two independent protection layers that cover each other's blind spots.

### What each layer does

**DNSCrypt Proxy** encrypts your DNS requests — every time your phone looks up a domain name. Without it, your ISP sees every website you visit even if they cannot read the content.

```
Without DNSCrypt:  Phone → ISP DNS → "user opened facebook.com at 14:32"
With DNSCrypt:     Phone → Encrypted → Quad9 / Cloudflare / Mullvad → nobody sees anything
```

**ProtonVPN WireGuard** encrypts all internet traffic and hides your real IP address. Websites see a ProtonVPN server IP instead of yours.

```
Without VPN:  Website sees your real IP → knows your country, city, ISP
With VPN:     Website sees ProtonVPN IP → knows nothing about you
```

### Why you need both

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

### What your ISP sees — before and after

**Before:**
```
[ISP log]: 192.168.1.x → facebook.com (14:32), youtube.com (14:35), bank.com (14:41)...
```

**After:**
```
[ISP log]: 192.168.1.x is sending encrypted packets to 89.105.214.x — that's it.
```

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
- Watchdog re-enforces IPv6 kill every 60 seconds

---

## DNS Resolvers

Three resolvers across three jurisdictions. Load balanced automatically — fastest one wins.

| Resolver | Type | No-Log | DNSSEC | Location |
|---|---|---|---|---|
| Cloudflare | DoH | ✅ | ✅ | Global anycast |
| Quad9 (nofilter) | DoH | ✅ | ✅ | Switzerland 🇨🇭 |
| Mullvad Base | DoH | ✅ | ✅ | Sweden 🇸🇪 |

All three have publicly available privacy policies and have passed independent audits. Quad9 is a nonprofit organization.

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

---

## Conflict Detection

The installer automatically detects and removes the following if found:

**Conflicting modules:** BindHosts, AdAway, Energized Protection, Systemless Hosts, DNS66, InviZible Pro, NextDNS, RethinkDNS, Cloudflared, SmartDNS, Dnsmasq, AdGuard, PersonalDNSfilter, Blokada, Nebulo, ControlD

**Conflicting apps:** org.adaway, org.blokada, dnsfilter.android, com.frostnerd.smokescreen, com.controld.app, com.nextdns.nextdns, com.celzero.bravedns, com.rethinkdns.rethink and others

> You will be asked before anything is removed. VOL UP to confirm, VOL DOWN to abort.

---

## Setup guide — Full privacy stack

### Step 1 — Flash this module

1. Install a compatible meta-module
2. Reboot
3. Flash the DNSCrypt module via your root manager
4. Reboot

Module status in your manager should show `Working 🌬🌬🌬`

### Step 2 — WireGuard tunnels (optional but recommended)

1. Install **WireGuard** from the Play Store
2. Import your `.conf` tunnel files (Add tunnel → Import from file)
3. Modify each tunnel config to remove the `DNS =` line — DNSCrypt handles DNS and the two must not conflict
4. Connect to your preferred server

### Step 3 — Verify

Open **dnsleaktest.com** and run the Extended Test.

A correct result looks like this:
- No entries from your ISP (Cosmote, Wind, Vodafone, etc.) ✅
- You see Cloudflare, Quad9, Mullvad entries ✅
- No IPv6 address visible anywhere ✅

---

## Configuration

Config file:
```
/storage/emulated/0/dnscrypt-proxy/dnscrypt-proxy.toml
```

Hot-reload supported — edit blocklists or resolver settings without reboot.

Monitoring dashboard:
```
http://127.0.0.1:5555
```

Log file:
```
/data/adb/dnscrypt-proxy.log
```

---

## Frequently Asked Questions

**Will my internet become slower?**
Only minimally. DNSCrypt adds around 30–50ms to DNS requests on average. Once a domain is cached — effectively zero delay. WireGuard is the fastest VPN protocol currently available and adds negligible overhead.

**⚠️ First Boot — Expected Delay**
On first boot or after switching networks (enabling VPN, switching between WiFi and mobile data), you may notice 5–10 seconds before DNS resolves normally.
This is expected. DNSCrypt-Proxy benchmarks all three resolvers and picks the fastest one. Once cached, subsequent connections are instant.

**Does DNSCrypt work without a VPN?**
Yes, completely independently. The VPN is an optional second layer. DNSCrypt alone already eliminates ISP DNS surveillance and blocks ads at the network level.

**Will this work with my current VPN?**
If your VPN uses a VPN slot (OpenVPN, IKEv2, most commercial apps) — yes, no conflict. If it uses WireGuard or DNS-over-VPN — remove the `DNS =` line from the tunnel config so DNSCrypt remains in control of DNS.

**Is it safe?**
The binary is built directly from the official [dnscrypt-proxy](https://github.com/DNSCrypt/dnscrypt-proxy) source. No patches, no modifications to the core. Resolvers used — Cloudflare, Quad9, Mullvad — all have public no-log policies and independent audits.

**What happens if dnscrypt-proxy crashes?**
The self-healing watchdog detects the failure and restarts it automatically. DNS remains blocked via iptables until the proxy is confirmed listening again — no traffic leaks to your ISP during the restart window.

---

## What's New in v2.1.15

### 🔍 Conflict Detection & Auto-Removal
Installer now automatically detects conflicting DNS modules and apps before installation and prompts for safe removal via volume keys.

### ✅ Meta-Module Verification
Installation aborts with clear instructions if no compatible meta-module is detected.

### 🔒 Boot-Time DNS Leak Prevention
DNS is blocked at boot via iptables until dnscrypt-proxy is confirmed listening on port 5354. The startup leak window is fully closed.

### 📵 Full IPv6 Kill
IPv6 disabled simultaneously at three levels — Android system properties, kernel sysctl, and ip6tables DROP policy. Re-enforced every 60 seconds by the watchdog.

### 🔁 Self-Healing Watchdog
Uses `ss` with `netstat` fallback for port detection. 30-second startup timeout with logging. Lifts the boot DNS block only after confirming dnscrypt is ready.

### 🛡️ Hardened Resolver List
Removed servers with policy conflicts. Active resolvers: Cloudflare, Quad9 (nofilter), Mullvad Base DoH.

### ⚡ DNSCrypt-Proxy 2.1.15 Core (upstream)
- Dynamic timeout reduction under high load
- More accurate cache statistics
- Enhanced monitoring UI
- Fixed IPv6 DoH stamp double-bracketing bug
- Proxy hostname pre-resolution via bootstrap resolvers

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

---

*Built and maintained by Tears Burn*
