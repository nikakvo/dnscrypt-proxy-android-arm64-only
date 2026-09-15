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
# -----------------------------------------------
CONF="/data/adb/dnscrypt-proxy-android.conf"
IPV6_KILL=1
QUIC_BLOCK=1
[ -f "$CONF" ] && . "$CONF"

STATE_DIR="/data/adb/dnscrypt-proxy-state"
DATA_DIR="/data/adb/dnscrypt-proxy"
LOG="/data/adb/dnscrypt-proxy.log"

mkdir -p "$STATE_DIR" "$DATA_DIR"

# Cleared on every boot. The xt_owner probe result is per-boot too:
# caching it across reboots would pin a wrong answer forever if the
# probe happened to run before the netfilter modules were loaded.
rm -f "$STATE_DIR/ipv6_killswitch_lifted" \
      "$STATE_DIR/ipv6_lift_confirmed" \
      "$STATE_DIR/metrics_shape_warned" \
      "$STATE_DIR/ipv6_check_done" \
      "$STATE_DIR/owner_match_unavailable" \
      "$STATE_DIR/failsafe_fired" \
      "$STATE_DIR/probe_method"

# shellcheck source=/dev/null
[ -f "$MODDIR/rules.sh" ] && . "$MODDIR/rules.sh"

# -----------------------------------------------
# Disable IPv6 - kernel + sysctl + ip6tables.
# Runs before any iptables work, and before the network
# is up, so it is deliberately unconditional here: at
# post-fs-data time there is no way to tell an IPv4
# network from an IPv6-only one, and guessing wrong in
# the permissive direction is exactly the leak this
# module exists to prevent. Fail closed now; service.sh
# re-evaluates once the network is actually up and lifts
# this if the device turns out to be IPv6-only.
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
# Install the DNS rules.
#
# Everything about how and why lives in rules.sh - including why the
# old `filter OUTPUT --dport 53 -j DROP` rule is gone (it could never
# match, because nat OUTPUT rewrites the port before filter OUTPUT
# ever sees the packet) and why the redirect is now inserted at the
# top of the chain rather than appended after netd's own rules.
#
# Flush first so a reload never stacks duplicates, and so rules left
# behind by r10 are cleaned up on upgrade.
# -----------------------------------------------
if command -v rules_install_dns >/dev/null 2>&1; then
  rules_flush_all
  rules_install_dns
  [ "$QUIC_BLOCK" = "1" ] && rules_install_quic
else
  echo "$(date): ERROR - rules.sh missing, DNS redirect NOT installed" >> "$LOG"
fi
