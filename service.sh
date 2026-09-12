#!/system/bin/sh
# dnscrypt-proxy Magisk / KernelSU / SUkiSU service script
# arm64-only module

MODDIR=${0%/*}

# -----------------------------------------------
# Settings (see post-fs-data.sh for the full description).
# Defaults match this module's purpose; the file only exists
# so they can be changed without editing scripts that get
# replaced on every module update.
# -----------------------------------------------
CONF="/data/adb/dnscrypt-proxy-android.conf"
IPV6_KILL=1
QUIC_BLOCK=1
[ -f "$CONF" ] && . "$CONF"

STATE_DIR="/data/adb/dnscrypt-proxy-state"
mkdir -p "$STATE_DIR"
IPV6_LIFTED_FLAG="$STATE_DIR/ipv6_killswitch_lifted"
# Set once the IPv6-only question is settled for this boot, so the
# expensive resolution probe stops running.
IPV6_CHECK_DONE="$STATE_DIR/ipv6_check_done"
HTTPD_PIDFILE="$STATE_DIR/httpd.pid"

# -----------------------------------------------
# Boot grace period for the failsafe.
# Generous on purpose - normal boot already involves
# waiting for storage mount + up to 90s for the binary
# to bind the port. This only fires when that whole
# pipeline has clearly stalled, not during normal boot.
# -----------------------------------------------
SCRIPT_START=$(date +%s)
BOOT_FAILSAFE_SECONDS=180

deadline_passed() {
  _now=$(date +%s)
  [ $(( _now - SCRIPT_START )) -ge "$BOOT_FAILSAFE_SECONDS" ]
}

# -----------------------------------------------
# Reduce watchdog priority - background process,
# should not compete with foreground apps for CPU
# -----------------------------------------------
renice -n 10 -p $$ 2>/dev/null

# -----------------------------------------------
# Kill any stale watchdog instance from a previous flash.
# When SUkiSU/KSU updates a module, the old service.sh
# keeps running until explicitly killed. Without this,
# the old watchdog races with the new one and launches
# dnscrypt-proxy before CONFIG_WAIT can protect it,
# causing [FATAL] double-starts seen in the logs.
#
# pgrep -f is not guaranteed on every busybox/toybox
# build. If it's missing or returns nothing usable,
# fall back to scanning /proc/*/cmdline directly so a
# stale watchdog can't silently survive a reboot/reflash
# and fight the new one for port 5354.
# -----------------------------------------------
MYPID=$$

kill_stale_watchdogs() {
  if command -v pgrep >/dev/null 2>&1; then
    for _pid in $(pgrep -f "dnscrypt-proxy-android/service\.sh" 2>/dev/null); do
      [ "$_pid" = "$MYPID" ] && continue
      kill "$_pid" 2>/dev/null
    done
  fi

  # Fallback / belt-and-suspenders: walk /proc directly.
  # Covers ROMs where pgrep -f is absent or behaves oddly.
  for _p in /proc/[0-9]*; do
    _pid=${_p#/proc/}
    [ "$_pid" = "$MYPID" ] && continue
    _cmdline=$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null)
    case "$_cmdline" in
      # Match this module's own path, not any command line that
      # merely mentions dnscrypt and a service.sh - the previous
      # pattern would also have killed a user's unrelated script.
      *dnscrypt-proxy-android/service.sh*) kill "$_pid" 2>/dev/null ;;
    esac
  done
}

kill_stale_watchdogs
unset _pid _p _cmdline

# -----------------------------------------------
# SELinux warning - some ROMs block DNAT at enforcing
# -----------------------------------------------
if [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
  echo "$(date): INFO - SELinux is Enforcing. DNS redirect should work on most ROMs." >> "/data/adb/dnscrypt-proxy.log"
fi

# -----------------------------------------------
# ss fallback to netstat for ROMs without ss
# Checks netstat availability before aliasing —
# avoids silent failures on minimal Busybox builds
# -----------------------------------------------
if ! command -v ss >/dev/null 2>&1; then
  if command -v netstat >/dev/null 2>&1; then
    ss() { netstat "$@"; }
  else
    # Neither ss nor netstat — use /proc/net/udp fallback
    # Checks if any process is bound to port 5354 (hex: 14EA)
    ss() {
      case "$*" in
        *5354*) awk 'NR>1 && $2 ~ /:14EA$/ {found=1; exit} END {exit !found}' /proc/net/udp 2>/dev/null && echo ":5354" || true ;;
        *) true ;;
      esac
    }
  fi
fi

DNSCRYPT_BIN="$MODDIR/system/bin/dnscrypt-proxy"
CONFIG="/storage/emulated/0/dnscrypt-proxy/dnscrypt-proxy.toml"
LOG="/data/adb/dnscrypt-proxy.log"
MODPROP="$MODDIR/module.prop"
WEBROOT="$MODDIR/webroot"

# -----------------------------------------------
# Helper: check if dnscrypt is listening on :5354
# Tries ss, /proc/net/udp, and /proc/net/tcp as fallbacks
# -----------------------------------------------
is_listening() {
  # Method 1: ss (standard)
  if ss -ulnp 2>/dev/null | grep -q ":5354"; then return 0; fi
  if ss -tlnp 2>/dev/null | grep -q ":5354"; then return 0; fi
  # Method 2: /proc/net/{udp,tcp}. Port 5354 is 0x14EA, and the
  # LOCAL address column is the second field, formatted as
  # <hex-addr>:<hex-port>. A bare `grep 14EA` matched anywhere on
  # the line - including the REMOTE port and any address whose hex
  # happens to contain those digits - so an outbound connection to
  # someone else's port 5354 read as "our daemon is up". Pin it to
  # the local column instead.
  if awk 'NR>1 && $2 ~ /:14EA$/ {found=1; exit} END {exit !found}' /proc/net/udp 2>/dev/null; then return 0; fi
  if awk 'NR>1 && $2 ~ /:14EA$/ {found=1; exit} END {exit !found}' /proc/net/tcp 2>/dev/null; then return 0; fi
  return 1
}

# -----------------------------------------------
# Helper: check if dnscrypt is actually ANSWERING
# queries, not just holding the port open.
#
# Why this exists: dnscrypt-proxy binds :5354 almost
# immediately, but can then spend minutes stuck trying
# to fetch its resolver/source lists over HTTPS (e.g.
# right after boot, before the network is fully usable).
# During that window the port is open but the daemon is
# not "usable yet" (see its own log line), so lifting the
# DNS block on port-listen alone is premature - and if the
# fetch keeps failing, dnscrypt eventually gives up,
# restarts, and the whole window repeats.
#
# We deliberately avoid nslookup/dig/drill here: toybox
# nslookup's flags differ across Android versions, and
# dig/drill aren't guaranteed to exist on every ROM. We
# also avoid hand-built raw DNS packets over /dev/udp,
# since portable hex-escape behavior in printf and binary-
# safe reads are not reliable across mksh/toybox sh/dash.
#
# Instead we use dnscrypt-proxy's own built-in self-test:
# `dnscrypt-proxy -resolve <domain>`. This doesn't start a
# second instance or touch the running daemon/socket - it
# spins up a short-lived internal resolver using the same
# binary and config, and asks it to resolve a domain via
# the configured upstream servers. Exit code 0 means it got
# a usable answer; anything else means the resolution path
# is not actually working yet, regardless of whether :5354
# is open. This piggybacks on logic dnscrypt-proxy already
# maintains itself, rather than us reimplementing DNS.
# -----------------------------------------------
is_resolving() {
  "$DNSCRYPT_BIN" -config "$CONFIG" -resolve example.com >/dev/null 2>&1
}

# -----------------------------------------------
# Helper: lift the boot DNS block set by post-fs-data.sh
# Called once dnscrypt is confirmed listening on :5354
# Only removes rules that actually exist - avoids
# redundant iptables calls on every watchdog tick
# -----------------------------------------------
lift_dns_block() {
  iptables -C OUTPUT -p udp --dport 53 -j DROP 2>/dev/null && \
    iptables -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null
  iptables -C OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null && \
    iptables -D OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null
}

# -----------------------------------------------
# Helper: remove the DNAT redirect (port 53 -> 127.0.0.1:5354)
# set up by post-fs-data.sh.
#
# BUG THIS FIXES: lift_dns_block() above only removes the
# OUTPUT DROP rule. It never touched this NAT redirect. If
# dnscrypt-proxy never actually came up (crash loop, stuck
# fetching resolver lists, corrupted cache on sdcard, etc.),
# the failsafe used to remove the DROP rule and declare
# victory - but every DNS packet was STILL being NATed to
# 127.0.0.1:5354, where nothing was listening. Net effect:
# DNS silently black-holed (UDP to a dead local port just
# times out) instead of being cleanly blocked. To the user
# this looked identical to "no internet", and it did NOT
# self-heal on reboot because whatever broke dnscrypt-proxy
# (e.g. a bad public-resolvers.md/minisig on external
# storage) persisted across reboots too - only a reflash
# (which resets those cache files in customize.sh) fixed it.
#
# The failsafe must remove THIS rule too, or "lifting the
# block" doesn't actually restore working DNS.
# -----------------------------------------------
remove_dns_nat_redirect() {
  iptables -t nat -C OUTPUT -p tcp --dport 53 -j DNAT --to-destination 127.0.0.1:5354 2>/dev/null && \
    iptables -t nat -D OUTPUT -p tcp --dport 53 -j DNAT --to-destination 127.0.0.1:5354 2>/dev/null
  iptables -t nat -C OUTPUT -p udp --dport 53 -j DNAT --to-destination 127.0.0.1:5354 2>/dev/null && \
    iptables -t nat -D OUTPUT -p udp --dport 53 -j DNAT --to-destination 127.0.0.1:5354 2>/dev/null
}

# -----------------------------------------------
# Helper: restore the DNAT redirect once dnscrypt-proxy
# actually catches up and starts resolving AFTER the
# failsafe already fired and removed it above. Without
# this, if dnscrypt-proxy comes alive late (e.g. network
# became usable a bit after the 180s grace period), DNS
# would keep going out in plaintext forever instead of
# being routed back through the proxy.
# -----------------------------------------------
restore_dns_nat_redirect() {
  iptables -t nat -C OUTPUT -p tcp --dport 53 -j DNAT --to-destination 127.0.0.1:5354 2>/dev/null || \
    iptables -t nat -A OUTPUT -p tcp --dport 53 -j DNAT --to-destination 127.0.0.1:5354 2>/dev/null
  iptables -t nat -C OUTPUT -p udp --dport 53 -j DNAT --to-destination 127.0.0.1:5354 2>/dev/null || \
    iptables -t nat -A OUTPUT -p udp --dport 53 -j DNAT --to-destination 127.0.0.1:5354 2>/dev/null
}

# -----------------------------------------------
# Failsafe: force-lift the DNS block even if dnscrypt
# never came up. This is the difference between
# "no internet for a few seconds at boot" (expected,
# fail-closed by design) and "no internet until I
# manually reflash the module" (the bug we're fixing).
#
# Only ever called after a generous boot grace period
# has elapsed (BOOT_FAILSAFE_DEADLINE below), so it does
# NOT weaken the anti-leak guarantee during normal boot —
# it only kicks in when something has clearly gone wrong
# (storage never mounted, binary won't bind, stale process
# fighting for the port, etc).
# -----------------------------------------------
FAILSAFE_TRIGGERED=0
force_lift_dns_block_failsafe() {
  [ "$FAILSAFE_TRIGGERED" -eq 1 ] && return
  echo "$(date): FAILSAFE - dnscrypt-proxy not up after boot grace period. Lifting DNS block AND removing the port-53 NAT redirect (dnscrypt isn't there to catch it) to avoid permanent loss of internet. Manual investigation needed." >> "$LOG"
  lift_dns_block
  remove_dns_nat_redirect
  FAILSAFE_TRIGGERED=1
}

# -----------------------------------------------
# NOTE ON A REJECTED APPROACH: an earlier version decided
# "IPv6-only network" by looking for an IPv4 default route in
# /proc/net/route. That is wrong on Android. netd uses policy
# routing - default routes live in per-network tables selected
# by `ip rule`, not in the main table that /proc/net/route
# exposes - so a perfectly healthy IPv4 device shows no default
# route there and the check fired on every device. Do not
# reintroduce it.
#
# The reliable signal is connectivity itself, and this script
# already has it: is_resolving() succeeds only when
# dnscrypt-proxy actually reached an upstream resolver. If DNS
# resolves, the network works and there is nothing to fix - no
# routing-table archaeology required.
# -----------------------------------------------
# Helper: is any real (non-loopback) interface actually up?
# Distinguishes "airplane mode / no network at all" from
# "there is a network, it just isn't giving us IPv4".
# -----------------------------------------------
has_live_interface() {
  for _if in /sys/class/net/*; do
    _name=${_if##*/}
    [ "$_name" = "lo" ] && continue
    [ "$(cat "$_if/operstate" 2>/dev/null)" = "up" ] && return 0
  done
  return 1
}

# -----------------------------------------------
# Helper: undo the IPv6 killswitch.
#
# WHY THIS EXISTS: post-fs-data.sh disables IPv6 unconditionally,
# because at that point the network does not exist yet and
# guessing permissively is the leak this module is built to
# prevent. That is the right call on an IPv4 or dual-stack
# network. On an IPv6-ONLY carrier it is fatal: such networks
# carry IPv4 traffic inside IPv6 via 464XLAT/clat, so dropping
# outbound IPv6 drops literally everything - the device looks
# bricked, and rebooting does not help because post-fs-data.sh
# re-applies the same rules on the next boot.
#
# So: fail closed at boot, then re-evaluate here once the
# network is genuinely up, and lift if IPv4 never appears.
# Once lifted we stay lifted for this boot (the flag file is
# cleared by post-fs-data.sh on the next one) - re-arming the
# killswitch the moment a route flickers back would flap the
# connection instead of fixing it.
# -----------------------------------------------
lift_ipv6_killswitch() {
  [ -f "$IPV6_LIFTED_FLAG" ] && return
  echo "$(date): IPv6 KILLSWITCH LIFTED - no IPv4 default route after the grace period while a network interface is up. This device appears to be on an IPv6-only network (464XLAT/clat), where blocking IPv6 blocks all traffic including IPv4-over-IPv6. Restoring IPv6 so the device has connectivity. Set IPV6_KILL=0 in $CONF to make this permanent and silence this." >> "$LOG"

  ip6tables -P INPUT   ACCEPT 2>/dev/null
  ip6tables -P OUTPUT  ACCEPT 2>/dev/null
  ip6tables -P FORWARD ACCEPT 2>/dev/null
  ip6tables -D INPUT  -i lo -j ACCEPT 2>/dev/null
  ip6tables -D OUTPUT -o lo -j ACCEPT 2>/dev/null

  echo 0 > /proc/sys/net/ipv6/conf/all/disable_ipv6     2>/dev/null
  echo 0 > /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null
  echo 1 > /proc/sys/net/ipv6/conf/all/accept_ra        2>/dev/null
  echo 1 > /proc/sys/net/ipv6/conf/default/accept_ra    2>/dev/null
  resetprop --delete net.ipv6.conf.all.disable_ipv6     2>/dev/null
  resetprop --delete net.ipv6.conf.default.disable_ipv6 2>/dev/null
  resetprop --delete net.ipv6.conf.lo.disable_ipv6      2>/dev/null

  : > "$IPV6_LIFTED_FLAG"
}

# -----------------------------------------------
# Helper: re-enforce IPv6 disable
# Some Android services re-enable IPv6 after boot.
# Skipped entirely when IPV6_KILL=0, or once the
# killswitch has been lifted for this boot - otherwise
# this would silently re-apply what lift_ipv6_killswitch()
# just removed, ten seconds later.
# -----------------------------------------------
enforce_ipv6_disable() {
  [ "$IPV6_KILL" = "1" ] || return
  [ -f "$IPV6_LIFTED_FLAG" ] && return

  echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6     2>/dev/null
  echo 1 > /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null
  echo 0 > /proc/sys/net/ipv6/conf/all/accept_ra        2>/dev/null
  echo 0 > /proc/sys/net/ipv6/conf/default/accept_ra    2>/dev/null
  resetprop net.ipv6.conf.all.disable_ipv6 1             2>/dev/null
  resetprop net.ipv6.conf.default.disable_ipv6 1         2>/dev/null

  # Re-apply ip6tables drop policy (Android may flush on network change)
  ip6tables -P INPUT   DROP  2>/dev/null
  ip6tables -P OUTPUT  DROP  2>/dev/null
  ip6tables -P FORWARD DROP  2>/dev/null
  ip6tables -D INPUT  -i lo -j ACCEPT 2>/dev/null
  ip6tables -D OUTPUT -o lo -j ACCEPT 2>/dev/null
  ip6tables -A INPUT  -i lo -j ACCEPT 2>/dev/null
  ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null
}

# -----------------------------------------------
# Helper: fetch live metrics from dnscrypt-proxy
# HTTP API and write to webroot/metrics.json
#
# The /api/metrics endpoint exposes real accumulated
# counters directly from the daemon — total queries,
# blocked, cache ratio, uptime, resolver health, etc.
#
# Strategy:
#   1. Try curl (preferred — handles timeouts cleanly)
#   2. Fall back to wget if curl unavailable
#   3. Validate response contains expected JSON key
#   4. Atomic write (tmp -> mv) — UI never reads partial JSON
#   5. On failure: keep last known good metrics.json
#      so the UI shows stale-but-valid data, not blank
# -----------------------------------------------
BLOCKLIST="/storage/emulated/0/dnscrypt-proxy/blocked-names.txt"
METRICS_URL="http://127.0.0.1:5555/api/metrics"
METRICS_JSON="$WEBROOT/metrics.json"
ACTION_LOG="/data/adb/dnscrypt-action.log"
BB="/data/adb/ksu/bin/busybox"
[ ! -x "$BB" ] && BB="/data/adb/magisk/busybox"
CTL_PORT=5556

# -----------------------------------------------
# HTTP server on 127.0.0.1:5556 via busybox httpd
# Serves webroot/ as home directory.
# CGI scripts in webroot/cgi-bin/ are auto-executed.
# -f = foreground (we background it with &)
# -p = bind to IPv4 loopback only — no IPv6 issues
# -----------------------------------------------
start_httpd() {
  # Kill only OUR previous instance, tracked by pidfile.
  # `pkill -f "busybox httpd"` used to be used here, which also
  # killed the control server of any OTHER module using busybox
  # httpd for its WebUI - a common pattern - on every boot and
  # on every restart of this script.
  if [ -f "$HTTPD_PIDFILE" ]; then
    _old=$(cat "$HTTPD_PIDFILE" 2>/dev/null)
    if [ -n "$_old" ] && [ -d "/proc/$_old" ]; then
      # confirm it is actually our httpd before killing it - PIDs
      # get reused, and killing a stranger is worse than leaking one
      case "$(tr '\0' ' ' < "/proc/$_old/cmdline" 2>/dev/null)" in
        *httpd*"$CTL_PORT"*) kill "$_old" 2>/dev/null ;;
      esac
    fi
    rm -f "$HTTPD_PIDFILE"
    unset _old
  fi
  sleep 1
  chmod +x "$WEBROOT/cgi-bin/"*.sh 2>/dev/null
  if [ ! -x "$BB" ]; then
    echo "$(date): ERROR - busybox not found, httpd cannot start" >> "$LOG"
    return 1
  fi
  "$BB" httpd -f -p 127.0.0.1:$CTL_PORT -h "$WEBROOT" &
  echo "$!" > "$HTTPD_PIDFILE"
  echo "$(date): busybox httpd started on 127.0.0.1:$CTL_PORT (PID $!)" >> "$LOG"
}

start_httpd

fetch_metrics() {
  local tmp="$WEBROOT/metrics.json.tmp"

  # Try curl first (more reliable timeout handling)
  if command -v curl >/dev/null 2>&1; then
    curl -sf --max-time 5 --connect-timeout 3 \
      "$METRICS_URL" -o "$tmp" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 5 "$METRICS_URL" -O "$tmp" 2>/dev/null
  else
    echo "$(date): WARNING - fetch_metrics: neither curl nor wget available" >> "$LOG"
    return 1
  fi

  # Validate: must contain "total_queries" key
  if [ -s "$tmp" ] && grep -q '"total_queries"' "$tmp" 2>/dev/null; then
    # -----------------------------------------------
    # Inject blocklist_domains: count lines in blocked-names.txt
    # sed removes the closing } and appends the new field + }
    # Only runs if the blocklist file exists
    # -----------------------------------------------
    if [ -f "$BLOCKLIST" ]; then
      local bl_count
      bl_count=$(grep -cv '^#\|^$' "$BLOCKLIST" 2>/dev/null || echo 0)
      # Append the field to the CLOSING brace only ($ = last line).
      # Without the $ anchor this substitution hit every line ending
      # in }, so any pretty-printed or nested JSON from the API came
      # back with the field injected several times and invalid.
      sed -i '$ s/}[[:space:]]*$/,\"blocklist_domains\":'"$bl_count"'}/' "$tmp" 2>/dev/null
      # If the API ever returns multi-line JSON, the closing brace may
      # not be on the last line at all - verify we did not corrupt it,
      # and fall back to the untouched response rather than feeding the
      # dashboard broken JSON.
      # Log this ONCE per boot, not on every tick. fetch_metrics runs
      # every 10s and this branch would otherwise append a line each
      # time - and the log is only trimmed in the not-listening path,
      # so a healthy daemon would grow it without bound.
      if ! grep -q '"blocklist_domains"' "$tmp" 2>/dev/null; then
        if [ ! -f "$STATE_DIR/metrics_shape_warned" ]; then
          echo "$(date): NOTE - could not inject blocklist_domains into metrics (unexpected JSON shape); serving API response as-is" >> "$LOG"
          : > "$STATE_DIR/metrics_shape_warned"
        fi
      fi
    fi
    mv "$tmp" "$METRICS_JSON" 2>/dev/null
    return 0
  else
    rm -f "$tmp" 2>/dev/null
    echo "$(date): WARNING - fetch_metrics: invalid or empty response from $METRICS_URL" >> "$LOG"
    return 1
  fi
}

# -----------------------------------------------
# Wait until /storage/emulated/0 is mounted
# and config file is accessible
# -----------------------------------------------
WAIT=0
while [ ! -f "$CONFIG" ]; do
  sleep 2
  WAIT=$((WAIT + 2))
  if deadline_passed; then
    echo "$(date): ERROR - config not found at $CONFIG, boot grace period exceeded" >> "$LOG"
    force_lift_dns_block_failsafe
    break
  fi
  if [ "$WAIT" -ge 60 ]; then
    echo "$(date): ERROR - config not found at $CONFIG after 60s" >> "$LOG"
    break
  fi
done

# -----------------------------------------------
# Track IPv6 check interval separately
# -----------------------------------------------
IPV6_CHECK_COUNTER=0
IPV6_PROBE_COUNTER=0
METRICS_COUNTER=0

# Track last known status to avoid unnecessary module.prop writes
LAST_STATUS=""

# -----------------------------------------------
# Main watchdog loop
# -----------------------------------------------
while true; do

  if ! is_listening; then

    # Rotate daemon log if too big (keep last 300 lines)
    if [ -f "$LOG" ]; then
      tail -n 300 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    fi

    echo "$(date): Starting dnscrypt-proxy..." >> "$LOG"

    # Wait for config to be accessible before launching.
    # Needed not just at boot — storage may be temporarily unavailable
    # after a pkill (network change, update-blocklist.sh, etc).
    # Without this, dnscrypt exits with [FATAL] and watchdog double-starts.
    CONFIG_WAIT=0
    while [ ! -f "$CONFIG" ] && [ "$CONFIG_WAIT" -lt 30 ]; do
      sleep 2
      CONFIG_WAIT=$((CONFIG_WAIT + 2))
    done
    if [ ! -f "$CONFIG" ]; then
      echo "$(date): WARNING - config not accessible, skipping start" >> "$LOG"
      if deadline_passed; then
        force_lift_dns_block_failsafe
      fi
      sleep 10
      continue
    fi

    "$DNSCRYPT_BIN" -config "$CONFIG" >> "$LOG" 2>&1 &

    READY=0
    for i in $(seq 1 90); do
      if is_listening; then
        READY=1
        break
      fi
      sleep 1
    done

    if [ "$READY" -eq 1 ]; then
      echo "$(date): dnscrypt-proxy listening on :5354, verifying it actually resolves..." >> "$LOG"

      # Port is open, but dnscrypt-proxy can still be stuck fetching
      # its source lists ("service is not usable yet" in its own log).
      # Give it up to 60s to prove it can actually answer a query
      # before we trust it enough to lift the DNS block. This is the
      # difference between "port open" and "DNS actually works" -
      # see the 25-minute restart-loop case this was added for.
      RESOLVING=0
      for i in $(seq 1 12); do
        if is_resolving; then
          RESOLVING=1
          break
        fi
        sleep 5
      done

      if [ "$RESOLVING" -eq 1 ]; then
        echo "$(date): dnscrypt-proxy ready on :5354 and resolving queries" >> "$LOG"
        lift_dns_block
      else
        echo "$(date): WARNING - dnscrypt-proxy listening but not resolving after 60s (likely stuck fetching sources). Will retry on next watchdog tick." >> "$LOG"
        if deadline_passed; then
          force_lift_dns_block_failsafe
        fi
      fi
    else
      echo "$(date): WARNING - dnscrypt-proxy did not bind :5354 in 90s" >> "$LOG"
      if deadline_passed; then
        force_lift_dns_block_failsafe
      fi
    fi

  fi

  # -----------------------------------------------
  # Outside the startup branch too: if we've been stuck
  # not-listening past the grace period for any reason
  # (e.g. binary crash-looping silently), make sure the
  # failsafe still fires on a later tick rather than only
  # at the exact moment of a failed start attempt.
  # -----------------------------------------------
  if ! is_listening && deadline_passed; then
    force_lift_dns_block_failsafe
  fi

  # -----------------------------------------------
  # Catch-up check: dnscrypt-proxy may have been listening
  # but not yet resolving on a previous tick (still fetching
  # sources). If the DNS block is still up, re-test resolution
  # here so we lift it as soon as it becomes ready, instead of
  # only retrying on the next full restart cycle.
  # Only bothers with the (slower) resolve test if the block
  # rule is actually still present, to avoid unnecessary load
  # once things are healthy and the block has already been lifted.
  # -----------------------------------------------
  if is_listening; then
    DROP_STILL_UP=0
    NAT_MISSING=0
    iptables -C OUTPUT -p udp --dport 53 -j DROP 2>/dev/null && DROP_STILL_UP=1
    iptables -t nat -C OUTPUT -p udp --dport 53 -j DNAT --to-destination 127.0.0.1:5354 2>/dev/null || NAT_MISSING=1

    if [ "$DROP_STILL_UP" -eq 1 ] || [ "$NAT_MISSING" -eq 1 ]; then
      if is_resolving; then
        if [ "$DROP_STILL_UP" -eq 1 ]; then
          echo "$(date): dnscrypt-proxy now resolving queries, lifting DNS block" >> "$LOG"
          lift_dns_block
        fi
        if [ "$NAT_MISSING" -eq 1 ]; then
          echo "$(date): dnscrypt-proxy now resolving queries, restoring NAT redirect (previously removed by failsafe)" >> "$LOG"
          restore_dns_nat_redirect
          FAILSAFE_TRIGGERED=0
        fi
      fi
    fi
  fi

  # -----------------------------------------------
  # Dynamic status update in module.prop
  # -----------------------------------------------
  if is_listening; then
    STATUS="Working 🌬🌬🌬"
  else
    STATUS="Not Working 📵❌📵"
  fi

  if [ "$STATUS" != "$LAST_STATUS" ]; then
    sed -i "s|Status:.*|Status: $STATUS|g" "$MODPROP" 2>/dev/null
    LAST_STATUS="$STATUS"
  fi

  # -----------------------------------------------
  # IPv6-only network check.
  #
  # Only meaningful once the network has had time to come up,
  # so it waits out the same boot grace period the DNS failsafe
  # uses. The condition is deliberately narrow: a live non-loopback
  # interface AND no working DNS. "No interface up" is airplane
  # mode, not an IPv6-only carrier, and must not trigger this -
  # which is why has_live_interface() is checked too.
  # -----------------------------------------------
  #
  # COST NOTE: is_resolving() is not free - it runs
  # `dnscrypt-proxy -resolve example.com`, which fires a burst of
  # real DNS queries (A, AAAA, TXT, MX, NS, CNAME, HINFO, HTTPS,
  # plus a PTR and resolver.dnscrypt.info). Calling it on every
  # 10-second tick floods the daemon's own query log, so the WebUI's
  # "Recent queries" panel fills with example.com and shows almost
  # none of the device's actual traffic. It also costs battery and
  # upstream requests for nothing.
  #
  # So this check is bounded. The failure it guards against - an
  # IPv6-only network with the killswitch on - shows up immediately
  # at boot and never later. Once resolution is confirmed working
  # even once, the question is settled for this boot and the check
  # switches off permanently. Until then it runs at most once a
  # minute, not once per tick.
  if [ "$IPV6_KILL" = "1" ] && [ ! -f "$IPV6_CHECK_DONE" ]; then
    IPV6_PROBE_COUNTER=$((IPV6_PROBE_COUNTER + 1))
    if [ "$IPV6_PROBE_COUNTER" -ge 6 ] && deadline_passed; then
      IPV6_PROBE_COUNTER=0
      if [ ! -f "$IPV6_LIFTED_FLAG" ]; then
        # Not yet lifted: is there a network that nothing gets through?
        if ! has_live_interface; then
          : # airplane mode - not an IPv6-only carrier, nothing to decide
        elif is_resolving; then
          # Connectivity is fine, so the killswitch is doing no harm.
          # Settled - stop probing for the rest of this boot.
          : > "$IPV6_CHECK_DONE"
        else
          lift_ipv6_killswitch
        fi
      else
        # Already lifted: did it help? Losing DNS has many causes and
        # only one of them is "IPv6 was blocked on an IPv6-only
        # network". If resolution is still dead two minutes on, IPv6
        # was not the cause - re-arm rather than leave the device
        # leaking IPv6 because of an unrelated outage.
        if is_resolving; then
          : > "$IPV6_CHECK_DONE"
        else
          _lift_age=$(( $(date +%s) - $(stat -c %Y "$IPV6_LIFTED_FLAG" 2>/dev/null || date +%s) ))
          if [ "$_lift_age" -ge 120 ]; then
            echo "$(date): IPv6 killswitch RE-ARMED - DNS is still not resolving 120s after lifting it, so IPv6 was not the cause. Restoring the block instead of leaving IPv6 open." >> "$LOG"
            rm -f "$IPV6_LIFTED_FLAG"
            enforce_ipv6_disable
            : > "$IPV6_CHECK_DONE"
          fi
          unset _lift_age
        fi
      fi
    fi
  fi


  # -----------------------------------------------
  # Re-enforce IPv6 disable every ~60s
  # -----------------------------------------------
  IPV6_CHECK_COUNTER=$((IPV6_CHECK_COUNTER + 1))
  if [ "$IPV6_CHECK_COUNTER" -ge 6 ]; then
    enforce_ipv6_disable
    IPV6_CHECK_COUNTER=0
  fi

  # -----------------------------------------------
  # Fetch live metrics from /api/metrics and write
  # to webroot/metrics.json for the dashboard
  # -----------------------------------------------
  # Poll metrics every tick while the screen is on, and only every
  # 6th tick (~60s) while it is off. The dashboard cannot be looked
  # at with the screen off, so a curl every 10 seconds around the
  # clock was pure standby drain.
  SCREEN_ON=1
  if [ -r /sys/class/backlight/panel0-backlight/brightness ]; then
    [ "$(cat /sys/class/backlight/panel0-backlight/brightness 2>/dev/null)" = "0" ] && SCREEN_ON=0
  elif command -v dumpsys >/dev/null 2>&1; then
    dumpsys power 2>/dev/null | grep -q "mWakefulness=Awake" || SCREEN_ON=0
  fi

  METRICS_COUNTER=$((METRICS_COUNTER + 1))
  if [ "$SCREEN_ON" -eq 1 ] || [ "$METRICS_COUNTER" -ge 6 ]; then
    fetch_metrics
    METRICS_COUNTER=0
  fi

  sleep 10
done
