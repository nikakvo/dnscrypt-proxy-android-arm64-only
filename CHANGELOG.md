# Changelog

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
