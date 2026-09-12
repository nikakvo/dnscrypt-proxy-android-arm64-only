#!/system/bin/sh
MODDIR=${0%/*}

# -----------------------------------------------
# Settings file. Lives in /data/adb so it survives
# module updates (Magisk/KernelSU replace $MODDIR wholesale).
# customize.sh creates it with defaults on first install;
# defaults below apply if it is missing or a key was removed.
#
#   IPV6_KILL=1   disable IPv6 entirely (leak prevention)
#   QUIC_BLOCK=1  drop outbound UDP/443 so browsers can't
#                 bypass this proxy via QUIC's built-in DoH
#
# Both default to 1 - that is what this module is for. They
# exist so a device that genuinely needs IPv6 or HTTP/3 can
# turn one off without editing scripts that get overwritten
# on every update.
# -----------------------------------------------
CONF="/data/adb/dnscrypt-proxy-android.conf"
IPV6_KILL=1
QUIC_BLOCK=1
[ -f "$CONF" ] && . "$CONF"

STATE_DIR="/data/adb/dnscrypt-proxy-state"
mkdir -p "$STATE_DIR"

# Cleared on every boot: service.sh sets this if it has to
# undo the IPv6 killswitch because the device turned out to
# have no IPv4 connectivity at all.
rm -f "$STATE_DIR/ipv6_killswitch_lifted" "$STATE_DIR/ipv6_lift_confirmed" "$STATE_DIR/metrics_shape_warned" "$STATE_DIR/ipv6_check_done" "$STATE_DIR/ipv6_lift_confirmed"

# -----------------------------------------------
# Disable IPv6 - kernel + sysctl + ip6tables.
# Runs before any iptables work, and before the network
# is up, so it is deliberately unconditional here: at
# post-fs-data time there is no way to tell an IPv4
# network from an IPv6-only one, and guessing wrong in
# the permissive direction is exactly the leak this
# module exists to prevent. Fail closed now; service.sh
# re-evaluates once the network is actually up and lifts
# this if the device turns out to be IPv6-only (see
# check_ipv4_reachable there).
# -----------------------------------------------
if [ "$IPV6_KILL" = "1" ]; then
  resetprop net.ipv6.conf.all.disable_ipv6 1
  resetprop net.ipv6.conf.default.disable_ipv6 1
  resetprop net.ipv6.conf.all.accept_redirects 0
  resetprop net.ipv6.conf.default.accept_redirects 0
  resetprop net.ipv6.conf.lo.disable_ipv6 1

  echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6      2>/dev/null
  echo 1 > /proc/sys/net/ipv6/conf/default/disable_ipv6  2>/dev/null
  echo 0 > /proc/sys/net/ipv6/conf/all/accept_ra         2>/dev/null
  echo 0 > /proc/sys/net/ipv6/conf/default/accept_ra     2>/dev/null

  ip6tables -P INPUT   DROP  2>/dev/null
  ip6tables -P OUTPUT  DROP  2>/dev/null
  ip6tables -P FORWARD DROP  2>/dev/null
  ip6tables -A INPUT  -i lo -j ACCEPT 2>/dev/null
  ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null
fi

# -----------------------------------------------
# Clean up any existing DNS redirect rules
# (prevents duplicates on reboot / module reload)
# -----------------------------------------------
iptables -t nat -D OUTPUT -p tcp --dport 53 -j DNAT --to-destination 127.0.0.1:5354 2>/dev/null
iptables -t nat -D OUTPUT -p udp --dport 53 -j DNAT --to-destination 127.0.0.1:5354 2>/dev/null

iptables -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null
iptables -D OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null

# -----------------------------------------------
# DNS leak prevention during boot:
# Block DNS until dnscrypt is up (service.sh lifts this,
# and force-lifts it if dnscrypt never comes up at all).
# -----------------------------------------------
iptables -C OUTPUT -p udp --dport 53 -j DROP 2>/dev/null || iptables -A OUTPUT -p udp --dport 53 -j DROP
iptables -C OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null || iptables -A OUTPUT -p tcp --dport 53 -j DROP

# -----------------------------------------------
# Redirect all DNS to dnscrypt-proxy on :5354
# -----------------------------------------------
iptables -t nat -C OUTPUT -p tcp --dport 53 -j DNAT --to-destination 127.0.0.1:5354 2>/dev/null || iptables -t nat -A OUTPUT -p tcp --dport 53 -j DNAT --to-destination 127.0.0.1:5354
iptables -t nat -C OUTPUT -p udp --dport 53 -j DNAT --to-destination 127.0.0.1:5354 2>/dev/null || iptables -t nat -A OUTPUT -p udp --dport 53 -j DNAT --to-destination 127.0.0.1:5354

# -----------------------------------------------
# Block QUIC (UDP 443) to prevent DNS policy bypass.
# Chrome, YouTube and other Google apps carry their own
# DoH over QUIC, which would sidestep this proxy entirely.
# Browsers fall back to TLS/TCP transparently; a handful of
# QUIC-only apps will not, which is why QUIC_BLOCK exists.
# -D first ensures no duplicate on reload/reboot.
# -----------------------------------------------
iptables -D OUTPUT -p udp --dport 443 -j DROP 2>/dev/null
if [ "$QUIC_BLOCK" = "1" ]; then
  iptables -A OUTPUT -p udp --dport 443 -j DROP
fi
