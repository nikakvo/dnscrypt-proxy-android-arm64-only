# Changelog

## v2.1.15-dev — 2026-05-19

- Auto-detects and removes conflicting DNS modules and apps before install
- Meta-module verification — aborts with clear instructions if missing
- Boot-time DNS leak prevention via iptables DROP until proxy is ready
- Full IPv6 kill at 3 levels: sysctl + resetprop + ip6tables DROP policy
- Self-healing watchdog with 30s startup timeout and port verification
- Hardened resolver list: Cloudflare / Quad9 nofilter / Mullvad Base DoH
- Professional uninstall: cleans iptables, ip6tables, IPv6 props, Private DNS
- DNSCrypt-Proxy 2.1.15 upstream core
