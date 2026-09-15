#!/system/bin/sh
# dnscrypt-proxy Magisk / KernelSU / SUkiSU service script
# arm64-only module

MODDIR=${0%/*}

CONF="/data/adb/dnscrypt-proxy-android.conf"
IPV6_KILL=1
QUIC_BLOCK=1
# Off by default, and that is deliberate. See the IPv6 block further
# down for why this exists at all and why it does not run unless the
# user explicitly asks for it.
IPV6_AUTO_LIFT=0
# Also off by default. See enforce_ipv6_disable() for the reasoning -
# short version: the firewall is what stops IPv6, not this.
IPV6_PER_IFACE_ENFORCE=0
[ -f "$CONF" ] && . "$CONF"

STATE_DIR="/data/adb/dnscrypt-proxy-state"
mkdir -p "$STATE_DIR"
IPV6_LIFTED_FLAG="$STATE_DIR/ipv6_killswitch_lifted"
IPV6_CHECK_DONE="$STATE_DIR/ipv6_check_done"
HTTPD_PIDFILE="$STATE_DIR/httpd.pid"

# -----------------------------------------------
# PATHS (changed in r11)
#
# The daemon now runs entirely out of /data/adb/dnscrypt-proxy.
# It used to read its config, its resolver cache and its 7.6 MB
# blocklist straight off /storage/emulated/0, which is FUSE: mounted
# late, invisible to this script's mount namespace on some ROMs, and
# completely absent before the first unlock on an FBE device. That is
# where the "config not accessible, skipping start" path came from,
# and why a reboot could leave the phone with the DNS redirect in
# place and no daemon behind it.
#
# /data/adb is mounted and readable at post-fs-data time, always.
# So the daemon no longer waits for anything.
#
# SD_DIR stays as the place the user edits things. service.sh copies
# the small, user-editable files inward whenever they change. If the
# sdcard never shows up, nothing breaks - the last synced copy in
# DATA_DIR is already there.
# -----------------------------------------------
DATA_DIR="/data/adb/dnscrypt-proxy"
SD_DIR="/storage/emulated/0/dnscrypt-proxy"
CONFIG="$DATA_DIR/dnscrypt-proxy.toml"
BLOCKLIST="$DATA_DIR/blocked-names.txt"
SYNC_FILES="dnscrypt-proxy.toml custom-blocked-names.txt allowed-names.txt allowed-ips.txt blocked-ips.txt"

DNSCRYPT_BIN="$MODDIR/system/bin/dnscrypt-proxy"
LOG="/data/adb/dnscrypt-proxy.log"
MODPROP="$MODDIR/module.prop"
WEBROOT="$MODDIR/webroot"
METRICS_URL="http://127.0.0.1:5555/api/metrics"
METRICS_JSON="$WEBROOT/metrics.json"
CTL_PORT=5556

BB="/data/adb/ksu/bin/busybox"
[ ! -x "$BB" ] && BB="/data/adb/magisk/busybox"

mkdir -p "$DATA_DIR"

# shellcheck source=/dev/null
[ -f "$MODDIR/rules.sh" ] && . "$MODDIR/rules.sh"

# If rules.sh is somehow missing, fail open rather than calling into
# undefined functions on every tick. No redirect is a worse privacy
# outcome, but a watchdog throwing "not found" ten times a second is a
# worse everything outcome.
if ! command -v rules_install_dns >/dev/null 2>&1; then
  echo "$(date): ERROR - rules.sh missing, running without iptables management" >> "$LOG"
  rules_install_dns()  { :; }
  rules_remove_dns()   { :; }
  rules_install_quic() { :; }
  rules_remove_quic()  { :; }
  rules_dns_present()  { return 0; }
fi

# -----------------------------------------------
# Boot grace period for the failsafe.
# Much shorter than r10's 180s, because with the config on /data and
# the resolver stamps pinned statically in the toml there is nothing
# left to wait for: no storage mount, no 60s netprobe, no source-list
# download. A healthy start is now a couple of seconds.
# -----------------------------------------------
SCRIPT_START=$(date +%s)
BOOT_FAILSAFE_SECONDS=90

deadline_passed() {
  _now=$(date +%s)
  [ $(( _now - SCRIPT_START )) -ge "$BOOT_FAILSAFE_SECONDS" ]
}

renice -n 10 -p $$ 2>/dev/null

# -----------------------------------------------
# Kill any stale watchdog instance from a previous flash.
# -----------------------------------------------
MYPID=$$

kill_stale_watchdogs() {
  if command -v pgrep >/dev/null 2>&1; then
    for _pid in $(pgrep -f "dnscrypt-proxy-android/service\.sh" 2>/dev/null); do
      [ "$_pid" = "$MYPID" ] && continue
      kill "$_pid" 2>/dev/null
    done
  fi

  for _p in /proc/[0-9]*; do
    _pid=${_p#/proc/}
    [ "$_pid" = "$MYPID" ] && continue
    _cmdline=$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null)
    case "$_cmdline" in
      *dnscrypt-proxy-android/service.sh*) kill "$_pid" 2>/dev/null ;;
    esac
  done
}

kill_stale_watchdogs
unset _pid _p _cmdline

# -----------------------------------------------
# Kill any dnscrypt-proxy left over from the previous watchdog.
# r10 killed the old service.sh but not the daemon it had started, so
# after a module update a process running the OLD binary kept holding
# :5354. The new watchdog saw the port open, concluded all was well,
# and the user ran the previous version until the next reboot.
# -----------------------------------------------
if pgrep -x dnscrypt-proxy >/dev/null 2>&1; then
  echo "$(date): killing dnscrypt-proxy left over from a previous instance" >> "$LOG"
  pkill -x dnscrypt-proxy 2>/dev/null
  sleep 1
  pkill -9 -x dnscrypt-proxy 2>/dev/null
fi

if [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
  echo "$(date): INFO - SELinux is Enforcing. DNS redirect should work on most ROMs." >> "$LOG"
fi

# -----------------------------------------------
# ss fallback to netstat, then to /proc/net directly
# -----------------------------------------------
if ! command -v ss >/dev/null 2>&1; then
  if command -v netstat >/dev/null 2>&1; then
    ss() { netstat "$@"; }
  else
    ss() {
      case "$*" in
        *5354*) awk 'NR>1 && $2 ~ /:14EA$/ {found=1; exit} END {exit !found}' /proc/net/udp 2>/dev/null && echo ":5354" || true ;;
        *) true ;;
      esac
    }
  fi
fi

# -----------------------------------------------
# Helper: is dnscrypt listening on :5354
# Port 5354 is 0x14EA and the LOCAL address is the second column of
# /proc/net/{udp,tcp}, so the match is pinned to that column - a bare
# grep for 14EA also hit remote ports and address bytes.
# -----------------------------------------------
is_listening() {
  if ss -ulnp 2>/dev/null | grep -q ":5354"; then return 0; fi
  if ss -tlnp 2>/dev/null | grep -q ":5354"; then return 0; fi
  if awk 'NR>1 && $2 ~ /:14EA$/ {found=1; exit} END {exit !found}' /proc/net/udp 2>/dev/null; then return 0; fi
  if awk 'NR>1 && $2 ~ /:14EA$/ {found=1; exit} END {exit !found}' /proc/net/tcp 2>/dev/null; then return 0; fi
  return 1
}

# -----------------------------------------------
# Helper: is dnscrypt actually ANSWERING, not just holding the port?
#
# CHANGED IN r11, and this one mattered.
#
# r10 ran `dnscrypt-proxy -config $CONFIG -resolve example.com`. That
# starts a SECOND process against the SAME config, which means the same
# `cache_file` paths and the same source definitions. Two dnscrypt-proxy
# processes could therefore refresh and rewrite public-resolvers.md and
# its .minisig at the same time. A half-written pair fails signature
# validation, and from then on the daemon refuses to start at all - the
# exact failure that could only be cleared by reflashing the module,
# because customize.sh is the only thing that replaced those files.
# It also fired a burst of A/AAAA/TXT/MX/NS/CNAME/HTTPS/PTR lookups on
# every probe, which is what filled the dashboard's query list with
# example.com instead of real traffic.
#
# Now we just ask the running daemon one ordinary question. The nat
# rules deliberately do NOT exempt loopback, so 127.0.0.1:53 is
# redirected to :5354 and a plain nslookup reaches the live listener.
# No second process, no shared cache files, one query.
# -----------------------------------------------
probe_log_once() {
  [ -f "$STATE_DIR/probe_method" ] && return
  echo "$1" > "$STATE_DIR/probe_method"
  echo "$(date): resolve probe is using: $1" >> "$LOG"
}

# -----------------------------------------------
# A raw DNS query packet: id 0xABCD, RD set, one question,
# example.com IN A. 29 bytes. Octal escapes, not \x, because \x is not
# portable across mksh / toybox printf / dash.
# -----------------------------------------------
dns_probe_packet() {
  printf '\253\315\001\000\000\001\000\000\000\000\000\000\007example\003com\000\000\001\000\001'
}

# Send it and see whether anything larger than the question comes back.
# A response carrying an answer is ~45 bytes; the 29-byte floor rejects
# both silence and a bare echo.
raw_dns_probe() {
  _len=$(dns_probe_packet | "$@" -u -w 3 127.0.0.1 5354 2>/dev/null | wc -c)
  [ "${_len:-0}" -gt 29 ]
}

# -----------------------------------------------
# Strict form: a real DNS answer out of the running daemon.
#
# CHANGED IN r11.2. r11.1 asked nslookup, and the log said what it
# thought of that:
#   resolve probe is using: monitoring API (no working nslookup found)
# Neither busybox nor toybox nslookup would answer against 127.0.0.1 on
# this device, so every probe fell through to the liveness check on the
# monitoring API - which returns 200 as soon as the UI binds, whether or
# not a single query can be resolved. That is why "ready and resolving"
# was logged at 14:14:51 while the daemon did not have a working server
# until 14:14:52.
#
# So the probe no longer depends on any resolver tool being present and
# well-behaved: it writes 29 bytes of DNS onto the wire itself. It also
# talks to :5354 directly rather than to :53, which removes the old
# dependency on the NAT redirect being installed for the probe to work.
# -----------------------------------------------
is_resolving_strict() {
  if [ -x "$BB" ]; then
    raw_dns_probe "$BB" nc && { probe_log_once "raw DNS query via busybox nc"; return 0; }
  fi
  if command -v nc >/dev/null 2>&1; then
    raw_dns_probe nc && { probe_log_once "raw DNS query via nc"; return 0; }
  fi
  if [ -x "$BB" ]; then
    "$BB" nslookup example.com 127.0.0.1 >/dev/null 2>&1 && \
      { probe_log_once "busybox nslookup"; return 0; }
  fi
  if command -v nslookup >/dev/null 2>&1; then
    nslookup example.com 127.0.0.1 >/dev/null 2>&1 && \
      { probe_log_once "toybox nslookup"; return 0; }
  fi
  return 1
}

# Is there any tool on this device that can actually ask a DNS question?
have_dns_probe_tool() {
  [ -x "$BB" ] && return 0
  command -v nc       >/dev/null 2>&1 && return 0
  command -v nslookup >/dev/null 2>&1 && return 0
  return 1
}

is_resolving() {
  is_resolving_strict && return 0

  # If a real probe tool exists and it said no, believe it.
  #
  # This is the bug r11.2 shipped. The monitoring API answers 200 the
  # moment the UI binds, whether or not a single query can be resolved,
  # and it was consulted whenever the DNS probe merely FAILED rather
  # than was missing. So at 14:14:51 nslookup correctly reported that
  # nothing resolved yet, the API overruled it, and the watchdog logged
  # "ready and resolving" a second before the first server came up. The
  # "no working nslookup found" label was wrong too - nslookup worked
  # fine on the next boot, it had just been telling the truth.
  #
  # The liveness check now only runs on a device that has no way to ask
  # a DNS question at all, which is what it was meant for.
  have_dns_probe_tool && return 1

  if command -v curl >/dev/null 2>&1; then
    curl -sf --max-time 3 "$METRICS_URL" 2>/dev/null | grep -q '"total_queries"' && \
      { probe_log_once "monitoring API (no DNS probe tool on this device)"; return 0; }
  fi
  return 1
}

# -----------------------------------------------
# Failsafe: with the daemon dead, the redirect NATs every DNS query to
# a port nobody is listening on. Nothing leaves the device and nothing
# comes back - indistinguishable from "no internet", and it does not
# heal on reboot because post-fs-data.sh reinstalls the same rules.
# After the grace period, tear the redirect down so the phone is
# usable, and put it straight back the moment the daemon recovers.
# -----------------------------------------------
FAILSAFE_TRIGGERED=0
failsafe_open_dns() {
  [ "$FAILSAFE_TRIGGERED" -eq 1 ] && return
  echo "$(date): FAILSAFE - dnscrypt-proxy is not up after ${BOOT_FAILSAFE_SECONDS}s. Removing the port-53 redirect and its leak guard so DNS is not black-holed. Queries will go out in plaintext until the daemon recovers." >> "$LOG"
  rules_remove_dns
  FAILSAFE_TRIGGERED=1
  : > "$STATE_DIR/failsafe_fired"
}

# -----------------------------------------------
# Helper: is any real (non-loopback) interface up?
# Distinguishes "airplane mode" from "there is a network, it just
# isn't giving us IPv4".
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
# NOTE ON A REJECTED APPROACH: an earlier version decided
# "IPv6-only network" by looking for an IPv4 default route in
# /proc/net/route. That is wrong on Android - netd uses policy routing,
# so default routes live in per-network tables and a perfectly healthy
# IPv4 device shows nothing there. Do not reintroduce it. Connectivity
# itself is the reliable signal.
# -----------------------------------------------
lift_ipv6_killswitch() {
  [ -f "$IPV6_LIFTED_FLAG" ] && return
  echo "$(date): IPv6 KILLSWITCH LIFTED - a network interface is up but nothing resolves. This device looks like it is on an IPv6-only network (464XLAT/clat), where blocking IPv6 blocks all traffic including IPv4-over-IPv6. Restoring IPv6. Set IPV6_KILL=0 in $CONF to make this permanent." >> "$LOG"

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

  # Opening IPv6 back up must not open IPv6 DNS with it.
  rules_install_dns

  : > "$IPV6_LIFTED_FLAG"
}

# Write a sysctl only when it does not already hold the wanted value.
sysctl_set() {
  [ -r "$1" ] || return 0
  [ "$(cat "$1" 2>/dev/null)" = "$2" ] && return 0
  echo "$2" > "$1" 2>/dev/null
}

IPV6_PROPS_SET=0

# -----------------------------------------------
# Re-assert the IPv6 killswitch. Android services do re-enable IPv6
# after boot, so this has to keep running - but it must be a NO-OP when
# nothing has actually changed.
#
# r11.0 rewrote all four sysctls, called resetprop twice and deleted
# then re-added the loopback ACCEPT rules on every pass, every 60
# seconds, regardless of state. dnscrypt-proxy saw the churn and logged
# "Network change detected; rotating DNSCrypt client state" once a
# minute, forever, throwing away its DNSCrypt client keys each time.
# The log from a clean install shows it at :49:59, :50:59, :51:59,
# :53:59 - exactly one minute apart, phase-locked to the watchdog loop
# that started at :48:59.
#
# Now: sysctls are compared before writing, the properties are set once
# per boot, and the loopback rules are checked with -C instead of being
# torn down and rebuilt.
# -----------------------------------------------
enforce_ipv6_disable() {
  [ "$IPV6_KILL" = "1" ] || return
  [ -f "$IPV6_LIFTED_FLAG" ] && return

  sysctl_set /proc/sys/net/ipv6/conf/all/disable_ipv6     1
  sysctl_set /proc/sys/net/ipv6/conf/default/disable_ipv6 1
  sysctl_set /proc/sys/net/ipv6/conf/all/accept_ra        0
  sysctl_set /proc/sys/net/ipv6/conf/default/accept_ra    0

  # -----------------------------------------------
  # Per-interface sysctl enforcement is OFF by default as of r11.5,
  # and this is a retraction of what r11.3 added.
  #
  # r11.3 walked every interface and forced disable_ipv6 back to 1. The
  # log from a two-hour run shows what that actually bought:
  #
  #   14:37:42 re-disabled IPv6 on: rmnet_data2
  #   14:38:48 re-disabled IPv6 on: rmnet_data3
  #   14:41:00 re-disabled IPv6 on: rmnet_data2
  #   ... every ~132s per interface, forever
  #
  # rmnet_data2 and rmnet_data3 are modem PDN contexts. The RIL brings
  # them back up with IPv6 on a timer; we switch it off; it switches it
  # back on. Nobody wins, and every round removes an address, which is
  # exactly what dnscrypt-proxy reports as "Network change detected" and
  # answers by throwing away its DNSCrypt client keys. The churn in the
  # log is entirely self-inflicted.
  #
  # It also buys nothing for the thing this module is for. What stops
  # IPv6 leaving the device is the ip6tables DROP policy below, which
  # holds regardless of what addresses exist on an interface. And apps
  # do not even try IPv6, because block_ipv6 in the toml means they
  # never get a AAAA record to try. The sysctl was belt-and-braces; on a
  # phone with modem PDNs it is a fight with the baseband instead.
  #
  # Forcing disable_ipv6 on rmnet PDNs is also not risk-free: on many
  # carriers the IMS context is IPv6-only, and that is VoLTE and SMS.
  #
  # Set IPV6_PER_IFACE_ENFORCE=1 if you want the old behaviour.
  # -----------------------------------------------
  if [ "$IPV6_PER_IFACE_ENFORCE" = "1" ]; then
    _redisabled=""
    for _c in /proc/sys/net/ipv6/conf/*; do
      _ifname=${_c##*/}
      [ "$_ifname" = "lo" ] && continue
      if [ -r "$_c/disable_ipv6" ] && [ "$(cat "$_c/disable_ipv6" 2>/dev/null)" != "1" ]; then
        echo 1 > "$_c/disable_ipv6" 2>/dev/null && _redisabled="$_redisabled $_ifname"
      fi
      sysctl_set "$_c/accept_ra" 0
    done

    # Rate-limited: log when the set of offending interfaces changes, or
    # once every 10 minutes. Otherwise a permanent tug-of-war with the
    # modem writes a line a minute and fills the log with the same fact.
    if [ -n "$_redisabled" ]; then
      _now=$(date +%s)
      if [ "$_redisabled" != "$IPV6_LAST_REDISABLED" ] || \
         [ $(( _now - ${IPV6_LAST_REDISABLED_AT:-0} )) -ge 600 ]; then
        echo "$(date): re-disabled IPv6 on:$_redisabled (something keeps turning it back on)" >> "$LOG"
        IPV6_LAST_REDISABLED="$_redisabled"
        IPV6_LAST_REDISABLED_AT="$_now"
      fi
      unset _now
    fi
    unset _c _ifname _redisabled
  fi

  if [ "$IPV6_PROPS_SET" -eq 0 ]; then
    resetprop net.ipv6.conf.all.disable_ipv6 1     2>/dev/null
    resetprop net.ipv6.conf.default.disable_ipv6 1 2>/dev/null
    IPV6_PROPS_SET=1
  fi

  # This is the actual killswitch. Verified every pass; cheap, and it
  # changes nothing when it is already correct.
  if ! ip6tables -S OUTPUT 2>/dev/null | grep -q '^-P OUTPUT DROP'; then
    echo "$(date): ip6tables OUTPUT policy was not DROP, restoring IPv6 killswitch" >> "$LOG"
    ip6tables -P INPUT   DROP 2>/dev/null
    ip6tables -P OUTPUT  DROP 2>/dev/null
    ip6tables -P FORWARD DROP 2>/dev/null
  fi
  ip6tables -C INPUT  -i lo -j ACCEPT 2>/dev/null || ip6tables -A INPUT  -i lo -j ACCEPT 2>/dev/null
  ip6tables -C OUTPUT -o lo -j ACCEPT 2>/dev/null || ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null
}

# -----------------------------------------------
# Fold custom-blocked-names.txt into the live blocklist.
#
# dnscrypt-proxy reads exactly one file - blocked_names_file, which is
# blocked-names.txt. custom-blocked-names.txt is a convenience of this
# module, and up to r11.2 it only ever reached the daemon when the
# Update Blocklist button ran a full download and re-merge. So adding one
# domain by hand meant either pulling 245k domains over the network again
# or waiting until the next time you happened to.
#
# Now a changed custom list is merged straight into blocked-names.txt and
# the daemon is reloaded. Sorted and deduplicated, so repeating this does
# not grow the file, and the next full update rebuilds from download +
# custom anyway, so the two paths cannot drift apart.
# -----------------------------------------------
merge_custom_into_blocklist() {
  _custom="$DATA_DIR/custom-blocked-names.txt"
  _merged="$DATA_DIR/.custom.merged"
  [ -f "$BLOCKLIST" ] || { unset _custom _merged; return 1; }
  [ -f "$_custom" ]   || { unset _custom _merged; return 1; }

  # Same normalisation update-blocklist.sh applies: a bare domain becomes
  # *.domain so subdomains match too.
  sed '/^#/d;/^$/d' "$_custom" 2>/dev/null | sed 's|^\([^*]\)|\*.\1|' | sort -u > "$DATA_DIR/.custom.norm"

  # Entries that were in the custom list last time and are not any more.
  # Without this, deleting a line from custom-blocked-names.txt would do
  # nothing until the next full download, because merging only ever adds.
  # Note this also drops the entry if the downloaded list happened to
  # contain it as well - the next full update puts it back.
  _removed_count=0
  if [ -f "$_merged" ]; then
    comm -23 "$_merged" "$DATA_DIR/.custom.norm" > "$DATA_DIR/.custom.gone" 2>/dev/null
    _removed_count=$(wc -l < "$DATA_DIR/.custom.gone" 2>/dev/null || echo 0)
  else
    : > "$DATA_DIR/.custom.gone"
  fi

  _before=$(wc -l < "$BLOCKLIST" 2>/dev/null || echo 0)

  if [ "$_removed_count" -gt 0 ]; then
    grep -vxF -f "$DATA_DIR/.custom.gone" "$BLOCKLIST" > "$BLOCKLIST.stripped" 2>/dev/null && \
      mv -f "$BLOCKLIST.stripped" "$BLOCKLIST"
    rm -f "$BLOCKLIST.stripped"
  fi

  { cat "$BLOCKLIST"; cat "$DATA_DIR/.custom.norm"; } | sort -u > "$BLOCKLIST.new" 2>/dev/null
  _after=$(wc -l < "$BLOCKLIST.new" 2>/dev/null || echo 0)

  # Sanity floor. The list may legitimately shrink by as many entries as
  # were removed from the custom file, but no further - anything beyond
  # that means a truncated sort or a full disk, and must not be allowed
  # to replace a working blocklist.
  _floor=$(( _before - _removed_count ))
  if [ "$_after" -ge "$_floor" ]; then
    mv -f "$BLOCKLIST.new" "$BLOCKLIST"
    cp -f "$DATA_DIR/.custom.norm" "$_merged" 2>/dev/null
    if [ "$_after" -ne "$_before" ]; then
      echo "$(date): merged custom-blocked-names.txt: $_before -> $_after (removed $_removed_count)" >> "$LOG"
    fi
  else
    rm -f "$BLOCKLIST.new"
    echo "$(date): WARNING - custom merge result looked wrong ($_before -> $_after, floor $_floor), kept the existing blocklist" >> "$LOG"
  fi

  rm -f "$DATA_DIR/.custom.norm" "$DATA_DIR/.custom.gone"
  unset _custom _merged _before _after _floor _removed_count
  return 0
}

sync_from_sdcard() {
  [ -d "$SD_DIR" ] || return 1
  _toml_changed=0
  _lists_changed=0
  _custom_changed=0
  for f in $SYNC_FILES; do
    [ -f "$SD_DIR/$f" ] || continue
    if [ ! -f "$DATA_DIR/$f" ] || [ "$(mtime_of "$SD_DIR/$f")" -gt "$(mtime_of "$DATA_DIR/$f")" ]; then
      cp -f "$SD_DIR/$f" "$DATA_DIR/$f" 2>/dev/null || continue
      echo "$(date): synced $f from sdcard" >> "$LOG"
      case "$f" in
        dnscrypt-proxy.toml)       _toml_changed=1 ;;
        custom-blocked-names.txt)  _custom_changed=1 ;;
        *)                         _lists_changed=1 ;;
      esac
    fi
  done
  unset f

  [ "$_custom_changed" -eq 1 ] && { merge_custom_into_blocklist && _lists_changed=1; }

  if [ "$_toml_changed" -eq 1 ]; then
    echo "$(date): config changed, restarting dnscrypt-proxy" >> "$LOG"
    pkill -x dnscrypt-proxy 2>/dev/null
  elif [ "$_lists_changed" -eq 1 ]; then
    echo "$(date): lists changed, reloading dnscrypt-proxy (SIGHUP)" >> "$LOG"
    pkill -HUP -x dnscrypt-proxy 2>/dev/null
  fi
  unset _toml_changed _lists_changed _custom_changed
}

# -----------------------------------------------
# Log rotation.
# r10 did `tail -n 300 $LOG > $LOG.tmp && mv $LOG.tmp $LOG`. The daemon
# holds the log open with O_APPEND, so after the mv it kept writing to
# the old, now unlinked inode: the new log stayed empty and the disk
# space was never actually reclaimed. Truncating in place keeps the
# same inode and the daemon's file descriptor stays valid.
# -----------------------------------------------
rotate_log() {
  [ -f "$LOG" ] || return
  _lines=$(wc -l < "$LOG" 2>/dev/null || echo 0)
  [ "$_lines" -le 600 ] && { unset _lines; return; }
  tail -n 300 "$LOG" > "$LOG.tmp" 2>/dev/null && cat "$LOG.tmp" > "$LOG" 2>/dev/null
  rm -f "$LOG.tmp"
  unset _lines
}

# -----------------------------------------------
# HTTP server on 127.0.0.1:5556 via busybox httpd
# -----------------------------------------------
start_httpd() {
  # Kill only OUR previous instance, tracked by pidfile. A blanket
  # `pkill -f "busybox httpd"` also killed the WebUI server of every
  # other module using busybox httpd.
  if [ -f "$HTTPD_PIDFILE" ]; then
    _old=$(cat "$HTTPD_PIDFILE" 2>/dev/null)
    if [ -n "$_old" ] && [ -d "/proc/$_old" ]; then
      case "$(tr '\0' ' ' < "/proc/$_old/cmdline" 2>/dev/null)" in
        *httpd*"$CTL_PORT"*) kill "$_old" 2>/dev/null ;;
      esac
    fi
    rm -f "$HTTPD_PIDFILE"
    unset _old
  fi
  chmod +x "$WEBROOT/cgi-bin/"*.sh 2>/dev/null
  if [ ! -x "$BB" ]; then
    echo "$(date): ERROR - busybox not found, httpd cannot start" >> "$LOG"
    return 1
  fi
  "$BB" httpd -f -p 127.0.0.1:$CTL_PORT -h "$WEBROOT" &
  echo "$!" > "$HTTPD_PIDFILE"
  echo "$(date): busybox httpd started on 127.0.0.1:$CTL_PORT (PID $!)" >> "$LOG"
}

# -----------------------------------------------
# Blocklist line count for the dashboard.
# r10 ran `grep -cv` over a 7.6 MB / 338k-line file every 10 seconds
# while the screen was on. Cache it and only recount when the file
# actually changes.
# -----------------------------------------------
BL_COUNT_CACHE=""
BL_COUNT_STAMP=""
blocklist_count() {
  _st="$(mtime_of "$BLOCKLIST"):$(stat -c %s "$BLOCKLIST" 2>/dev/null || echo 0)"
  if [ -z "$BL_COUNT_CACHE" ] || [ "$_st" != "$BL_COUNT_STAMP" ]; then
    BL_COUNT_CACHE=$(grep -cv '^#\|^$' "$BLOCKLIST" 2>/dev/null || echo 0)
    BL_COUNT_STAMP="$_st"
  fi
  unset _st
  echo "$BL_COUNT_CACHE"
}

fetch_metrics() {
  _tmp="$WEBROOT/metrics.json.tmp"

  if command -v curl >/dev/null 2>&1; then
    curl -sf --max-time 5 --connect-timeout 3 "$METRICS_URL" -o "$_tmp" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 5 "$METRICS_URL" -O "$_tmp" 2>/dev/null
  else
    return 1
  fi

  if [ -s "$_tmp" ] && grep -q '"total_queries"' "$_tmp" 2>/dev/null; then
    if [ -f "$BLOCKLIST" ]; then
      _bl=$(blocklist_count)
      # Anchor the substitution to the LAST line. Without $, any
      # pretty-printed JSON got the field injected on every line
      # ending in } and came back invalid.
      sed -i '$ s/}[[:space:]]*$/,\"blocklist_domains\":'"$_bl"'}/' "$_tmp" 2>/dev/null
      if ! grep -q '"blocklist_domains"' "$_tmp" 2>/dev/null; then
        if [ ! -f "$STATE_DIR/metrics_shape_warned" ]; then
          echo "$(date): NOTE - could not inject blocklist_domains into metrics (unexpected JSON shape); serving API response as-is" >> "$LOG"
          : > "$STATE_DIR/metrics_shape_warned"
        fi
      fi
      unset _bl
    fi
    mv "$_tmp" "$METRICS_JSON" 2>/dev/null
    unset _tmp
    return 0
  fi
  rm -f "$_tmp" 2>/dev/null
  unset _tmp
  return 1
}

# -----------------------------------------------
# Startup
# -----------------------------------------------
start_httpd

# The config ships with the module and is installed to DATA_DIR by
# customize.sh, so it is already there. This is only a safety net for
# the case where someone deleted it by hand.
if [ ! -f "$CONFIG" ] && [ -f "$MODDIR/config/dnscrypt-proxy.toml" ]; then
  echo "$(date): config missing from $DATA_DIR, restoring module default" >> "$LOG"
  cp -f "$MODDIR/config/dnscrypt-proxy.toml" "$CONFIG" 2>/dev/null
fi

IPV6_CHECK_COUNTER=0
IPV6_PROBE_COUNTER=0
IPV6_WARN_COUNT=0
METRICS_COUNTER=0
SYNC_COUNTER=0
DUMPSYS_COUNTER=0
ROTATE_COUNTER=0
IPV6_LAST_REDISABLED=""
IPV6_LAST_REDISABLED_AT=0
SCREEN_CACHED=""
SD_SEEDED=0
LAST_STATUS=""

# -----------------------------------------------
# Main watchdog loop
# -----------------------------------------------
while true; do

  if ! is_listening; then
    rotate_log
    echo "$(date): Starting dnscrypt-proxy..." >> "$LOG"

    if [ ! -f "$CONFIG" ]; then
      echo "$(date): WARNING - $CONFIG does not exist, cannot start" >> "$LOG"
      deadline_passed && failsafe_open_dns
      sleep 10
      continue
    fi

    # -config is given an absolute path, but dnscrypt-proxy resolves
    # the relative filenames inside the toml (blocked-names.txt and
    # friends) against its working directory, so cd there first.
    ( cd "$DATA_DIR" && "$DNSCRYPT_BIN" -config "$CONFIG" >> "$LOG" 2>&1 ) &

    READY=0
    for i in $(seq 1 60); do
      if is_listening; then READY=1; break; fi
      sleep 1
    done

    if [ "$READY" -eq 1 ]; then
      # Install the rules BEFORE probing, not after. is_resolving asks
      # 127.0.0.1:53 and relies on the nat redirect to land that on
      # :5354 - probing first would fail for want of the very rule the
      # probe result is used to decide about.
      rules_install_dns

      RESOLVING=0
      for i in $(seq 1 10); do
        if is_resolving; then RESOLVING=1; break; fi
        sleep 3
      done
      if [ "$RESOLVING" -eq 1 ]; then
        echo "$(date): dnscrypt-proxy ready on :5354 and resolving" >> "$LOG"
        FAILSAFE_TRIGGERED=0
        rm -f "$STATE_DIR/failsafe_fired"
      else
        echo "$(date): WARNING - listening on :5354 but not resolving yet" >> "$LOG"
        deadline_passed && failsafe_open_dns
      fi
    else
      echo "$(date): WARNING - dnscrypt-proxy did not bind :5354 in 60s" >> "$LOG"
      deadline_passed && failsafe_open_dns
    fi
  fi

  if ! is_listening && deadline_passed; then
    failsafe_open_dns
  fi

  # -----------------------------------------------
  # Rule maintenance, every tick.
  #
  # netd rebuilds these chains on connectivity changes, VPN start and
  # tethering toggles, which silently takes the redirect out from under
  # us. r10 only re-checked inside a branch that required the daemon to
  # already be listening AND the (dead) DROP rule to still be present,
  # so in practice the redirect could stay missing indefinitely and DNS
  # quietly went out in plaintext.
  # -----------------------------------------------
  if is_listening; then
    if ! rules_dns_present; then
      # Reinstall on the strength of the port being open alone. Do NOT
      # gate this on is_resolving: that probe goes to 127.0.0.1:53 and
      # only works BECAUSE of the redirect, so requiring it here would
      # deadlock - the rule stays missing because the probe fails, and
      # the probe fails because the rule is missing.
      echo "$(date): DNS redirect missing (netd flush or failsafe), reinstalling" >> "$LOG"
      rules_install_dns
      FAILSAFE_TRIGGERED=0
      rm -f "$STATE_DIR/failsafe_fired"
    fi
    [ "$QUIC_BLOCK" = "1" ] && rules_install_quic
  fi

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
  # Sync user edits from the sdcard, every ~60s.
  # Cheap: five small files, mtime comparison only.
  # -----------------------------------------------
  SYNC_COUNTER=$((SYNC_COUNTER + 1))
  if [ "$SYNC_COUNTER" -ge 6 ]; then
    SYNC_COUNTER=0
    if [ -d "$SD_DIR" ]; then
      if [ "$SD_SEEDED" -eq 0 ]; then
        seed_sdcard
        SD_SEEDED=1
      fi
      sync_from_sdcard
    fi
  fi

  # -----------------------------------------------
  # IPv6-only network handling.
  #
  # CHANGED IN r11.2, and this is a correctness fix, not a tuning one.
  #
  # Killing IPv6 is the whole point of this module. r11 shipped with an
  # automatic escape hatch: if nothing resolved for a while and an
  # interface was up, it concluded the device must be on an IPv6-only
  # carrier and tore the killswitch down by itself. The intent was to
  # avoid bricking connectivity on a 464XLAT network, where blocking
  # IPv6 blocks IPv4-over-IPv6 too.
  #
  # The problem is what that costs. "Nothing resolves" has many causes -
  # captive portal, a VPN coming up, upstream outage, the daemon
  # restarting - and on any of them the module would silently switch off
  # its own core protection, which is precisely what the user installed
  # it for. A leak-prevention feature that disarms itself on a heuristic
  # is worse than one that fails loudly.
  #
  # So it is now opt-in: IPV6_AUTO_LIFT=1 in the settings file. Default
  # is 0, the killswitch stays on, full stop. What remains by default is
  # a single diagnostic line in the log pointing at the setting, logged
  # once per boot, so an IPv6-only network is still identifiable instead
  # of being a silent dead phone.
  # -----------------------------------------------
  if [ "$IPV6_KILL" = "1" ] && [ ! -f "$IPV6_CHECK_DONE" ]; then
    IPV6_PROBE_COUNTER=$((IPV6_PROBE_COUNTER + 1))
    if [ "$IPV6_PROBE_COUNTER" -ge 6 ] && deadline_passed; then
      IPV6_PROBE_COUNTER=0

      if [ "$IPV6_AUTO_LIFT" != "1" ]; then
        # Diagnostic only. Never touches the killswitch.
        if ! has_live_interface; then
          :
        elif is_resolving_strict; then
          : > "$IPV6_CHECK_DONE"
        else
          IPV6_WARN_COUNT=$((IPV6_WARN_COUNT + 1))
          if [ "$IPV6_WARN_COUNT" -ge 3 ]; then
            echo "$(date): NOTE - a network interface is up but DNS is not resolving, and the IPv6 killswitch is active. Usual causes are a captive portal, a VPN still connecting, or an upstream outage. If this device is on an IPv6-only carrier (464XLAT), blocking IPv6 also blocks IPv4 and nothing will work until you set IPV6_AUTO_LIFT=1 or IPV6_KILL=0 in $CONF. Not lifting anything on my own." >> "$LOG"
            : > "$IPV6_CHECK_DONE"
          fi
        fi

      elif [ ! -f "$IPV6_LIFTED_FLAG" ]; then
        if ! has_live_interface; then
          :
        elif is_resolving_strict; then
          : > "$IPV6_CHECK_DONE"
        else
          lift_ipv6_killswitch
        fi

      else
        # Already lifted: did it actually help? If DNS is still dead two
        # minutes later, IPv6 was not the cause - re-arm rather than
        # leave the device leaking IPv6 over an unrelated outage.
        if is_resolving_strict; then
          : > "$IPV6_CHECK_DONE"
        else
          _lift_age=$(( $(date +%s) - $(stat -c %Y "$IPV6_LIFTED_FLAG" 2>/dev/null || date +%s) ))
          if [ "$_lift_age" -ge 120 ]; then
            echo "$(date): IPv6 killswitch RE-ARMED - DNS still not resolving 120s after lifting it, so IPv6 was not the cause." >> "$LOG"
            rm -f "$IPV6_LIFTED_FLAG"
            enforce_ipv6_disable
            : > "$IPV6_CHECK_DONE"
          fi
          unset _lift_age
        fi
      fi
    fi
  fi

  IPV6_CHECK_COUNTER=$((IPV6_CHECK_COUNTER + 1))
  if [ "$IPV6_CHECK_COUNTER" -ge 6 ]; then
    enforce_ipv6_disable
    IPV6_CHECK_COUNTER=0
  fi

  # Rotate the log on a timer, not only when the daemon is being
  # (re)started. r11 put rotate_log inside the not-listening branch, so
  # on a healthy device - which never enters that branch - the log grew
  # without bound. Every ~10 minutes is plenty.
  ROTATE_COUNTER=$((ROTATE_COUNTER + 1))
  if [ "$ROTATE_COUNTER" -ge 60 ]; then
    rotate_log
    ROTATE_COUNTER=0
  fi

  # -----------------------------------------------
  # Metrics: every tick with the screen on, every ~60s with it off.
  # -----------------------------------------------
  SCREEN_ON=1
  if [ -r /sys/class/backlight/panel0-backlight/brightness ]; then
    [ "$(cat /sys/class/backlight/panel0-backlight/brightness 2>/dev/null)" = "0" ] && SCREEN_ON=0
  elif [ -r /sys/class/backlight/panel1-backlight/brightness ]; then
    [ "$(cat /sys/class/backlight/panel1-backlight/brightness 2>/dev/null)" = "0" ] && SCREEN_ON=0
  elif command -v dumpsys >/dev/null 2>&1; then
    # dumpsys is expensive - r10 ran it on every 10-second tick. Consult
    # it once a minute and reuse the answer in between; the worst case is
    # being one minute late to notice the screen went off.
    DUMPSYS_COUNTER=$((DUMPSYS_COUNTER + 1))
    if [ -z "$SCREEN_CACHED" ] || [ "$DUMPSYS_COUNTER" -ge 6 ]; then
      DUMPSYS_COUNTER=0
      if dumpsys power 2>/dev/null | grep -q "mWakefulness=Awake"; then
        SCREEN_CACHED=1
      else
        SCREEN_CACHED=0
      fi
    fi
    SCREEN_ON="$SCREEN_CACHED"
  fi

  METRICS_COUNTER=$((METRICS_COUNTER + 1))
  if [ "$SCREEN_ON" -eq 1 ] || [ "$METRICS_COUNTER" -ge 6 ]; then
    fetch_metrics
    METRICS_COUNTER=0
  fi

  sleep 10
done
