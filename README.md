# DNSCrypt-Proxy Android — arm64

### by Tears Burn | v2.1.15-r1 | SUkiSU Ultra · KernelSU · Magisk

---

## What is this?

A self-built arm64 module that forces **all DNS traffic** on your device through an encrypted proxy, completely bypassing your ISP's DNS servers. No ISP snooping, no DNS hijacking, no tracking.

---

## Requirements

- arm64 device only
- SUkiSU Ultra / KernelSU / Magisk with root
- Android 9+
- One of the following **meta-modules installed first**:

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
4. The installer will automatically:
   - Verify meta-module is present
   - Scan for conflicting DNS modules and apps
   - Prompt you to remove conflicts if found *(VOL UP = yes / VOL DOWN = abort)*
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

## How It Works

```
App DNS request
      ↓
iptables redirect (port 53 → 127.0.0.1:5354)
      ↓
dnscrypt-proxy (encrypted + authenticated)
      ↓
Cloudflare / Quad9 / Mullvad  ← fastest wins
```

- ISP sees **encrypted traffic only** — not your DNS queries
- Private DNS (Android 9+) is disabled on install
- IPv6 is fully killed — no IPv6 leak vectors
- QUIC (UDP 443) is blocked — prevents DoH bypass via Chrome/YouTube
- All DNS is blocked at boot until proxy is confirmed ready — no startup leak window

---

## DNS Resolvers

Three resolvers across three jurisdictions. Load balanced automatically — fastest one wins.

| Resolver | Type | No-Log | Location |
|---|---|---|---|
| Cloudflare | DoH | ✅ | Global anycast |
| Quad9 (nofilter) | DoH | ✅ | Switzerland |
| Mullvad Base | DoH | ✅ | Sweden |

---

## Configuration

Config file location:
```
/storage/emulated/0/dnscrypt-proxy/dnscrypt-proxy.toml
```

Hot-reload supported — edit blocklists or settings without reboot.

Monitoring dashboard:
```
http://127.0.0.1:5555
```

Log file:
```
/data/adb/dnscrypt-proxy.log
```

---

## What's New in v2.1.15-r1

### 🔒 QUIC Block *(new)*
UDP port 443 is now blocked via iptables to prevent DNS policy bypass via QUIC.
Chrome, YouTube and Google apps use QUIC with built-in DoH that can bypass
dnscrypt-proxy. Browsers silently fall back to TLS/TCP — no user impact.
Rule is cleanly removed on uninstall.

### 🔁 Watchdog — Port-Based Process Detection *(fix)*
Replaced unreliable `pgrep -x` with `ss` port check. The old method was
matching the watchdog script itself, causing a spurious restart loop and
`FATAL: bind: address already in use` errors every 10 seconds in the log.

### 📊 Status — Accurate Health Check *(fix)*
Removed `nslookup` upstream check — it is a Termux binary unavailable in
`/system/bin/`, causing status to always show `DNS Upstream Fail` even when
everything was working. Status now uses reliable `ss` port check.

---

## What's New in v2.1.15

### 🔍 Conflict Detection & Auto-Removal *(new)*
Installer now automatically detects conflicting DNS modules and apps before
installation. User is prompted via volume keys to remove them safely.

### ✅ Meta-Module Verification *(new)*
Installation aborts with clear instructions if no compatible meta-module is detected.

### 🔒 Boot-Time DNS Leak Prevention *(new)*
DNS is blocked at boot via iptables until dnscrypt-proxy is confirmed listening
on port 5354. The startup leak window is now closed.

### 📵 Full IPv6 Kill *(improved)*
IPv6 disabled at three levels simultaneously — Android system properties, kernel
sysctl and ip6tables DROP policy. Re-enforced every 60 seconds by the watchdog.

### 🔁 Self-Healing Watchdog *(improved)*
Watchdog uses `ss` with `netstat` fallback for port detection, 30-second startup
timeout with logging, and lifts the boot DNS block only after confirming
dnscrypt is ready.

### 🛡️ Hardened Resolver List *(improved)*
Removed servers with policy conflicts. Active list: Cloudflare, Quad9 (nofilter),
Mullvad Base DoH.

### ⚡ DNSCrypt-Proxy 2.1.15 Core *(upstream)*
- Dynamic timeout reduction under high load
- More accurate cache statistics
- Enhanced monitoring UI
- Fixed IPv6 DoH stamp double-bracketing bug
- Proxy hostname pre-resolution via bootstrap resolvers

---

## Uninstall

Remove the module via SUkiSU / KernelSU / Magisk and reboot. The uninstaller will automatically:
- Kill the dnscrypt-proxy process
- Remove all iptables and ip6tables rules including QUIC block
- Restore IPv6 to default
- Restore Android Private DNS to default (opportunistic)
- Remove config directory and log file

---

## Notes

- Module status updates every 10 seconds in your module manager
- On first install, config is written fresh. Existing config is backed up with a timestamp
- IPv6 re-enforcement every ~60 seconds is intentional
- QUIC block may affect UDP-based gaming on port 443 — disable by removing the rule from `post-fs-data.sh` if needed

---

*Built and maintained by Tears Burn*
