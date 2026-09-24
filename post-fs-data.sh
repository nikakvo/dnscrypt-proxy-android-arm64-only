#!/system/bin/sh
# post-fs-data.sh - runs early in boot, before the network is up.
# Arms the IPv6 killswitch and installs the DNS redirect so there is no
# window where DNS can leave the device in plaintext. service.sh starts
# the daemon behind the redirect a few seconds later.

MODDIR=${0%/*}

if [ ! -f "$MODDIR/sh/common.sh" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] sh/common.sh missing - DNS redirect NOT installed, reflash the module" >> /data/adb/dnscrypt-proxy.log
  exit 0
fi
# shellcheck source=/dev/null
. "$MODDIR/sh/common.sh"
load_settings

mkdir -p "$STATE_DIR" "$DATA_DIR"

# Per-boot state. The xt_owner probe result is per-boot too: caching it
# across reboots would pin a wrong answer forever if it once ran before
# the netfilter modules were loaded.
rm -f "$STATE_DIR/ipv6_killswitch_lifted" \
      "$STATE_DIR/ipv6_lift_confirmed" \
      "$STATE_DIR/metrics_shape_warned" \
      "$STATE_DIR/ipv6_check_done" \
      "$STATE_DIR/owner_match_unavailable" \
      "$STATE_DIR/failsafe_fired" \
      "$STATE_DIR/probe_method" \
      "$HEALTH_FILE" "$HEALTH_FILE.tmp" \
      "$DAEMON_PIDFILE" "$WATCHDOG_PIDFILE" "$UPDATE_PIDFILE" \
      "$STATE_DIR/probe_queries" "$STATE_DIR/ip_mode_applied" \
      "$STATE_DIR/ip6_nat" "$STATE_DIR/paused_until" \
      "$STATE_DIR/update.pending" "$STATE_DIR/watchdog.wake" \
      "$STATE_DIR/hotspot_applied" "$STATE_DIR/ipt_wait"
# A lock or a half-finished build from before the reboot is meaningless now,
# and the pid inside the lock may already belong to something else.
rm -rf "$STATE_DIR/blocklist.lock" "$DATA_DIR/sources/.work" \
       "$STATE_DIR/hotspot.lock" 2>/dev/null

# -----------------------------------------------
# DNS rules. Flush first so a reload never stacks duplicates and rules
# left behind by older versions are cleaned up. See sh/rules.sh.
# -----------------------------------------------
if [ "$RULES_OK" -eq 1 ]; then
  rules_flush_all
  # IP mode first: it decides whether IPv6 is on and whether IPv6 DNS is
  # redirected. "ipv4" (the default) is unconditional fail-closed: at
  # post-fs-data there is no telling an IPv4 network from an IPv6-only one.
  apply_ip_mode
  rules_install_dns
  [ "$QUIC_BLOCK" = "1" ] && rules_install_quic
else
  log_error "sh/rules.sh missing - DNS redirect NOT installed"
fi
