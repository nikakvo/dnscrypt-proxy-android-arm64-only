#!/system/bin/sh
# shellcheck shell=sh disable=SC2034
#
# sh/common.sh - shared by post-fs-data.sh, service.sh and ctl.sh.
#
# Only defines variables and functions; sourcing it does nothing else.
# Before r12 every script carried its own copy of the paths and helpers,
# and they drifted: service.sh called mtime_of and seed_sdcard, which only
# existed in update-blocklist.sh or nowhere at all, so the sdcard mirror
# never synced anything inward. One file, one definition.
#
# POSIX sh (mksh / toybox / busybox ash). No bashisms.

MODULE_ID="dnscrypt-proxy-android"
MODDIR="${MODDIR:-/data/adb/modules/$MODULE_ID}"

# ── Paths ────────────────────────────────────────────────────────────────────
DATA_DIR="/data/adb/dnscrypt-proxy"
SD_DIR="/storage/emulated/0/dnscrypt-proxy"
STATE_DIR="/data/adb/dnscrypt-proxy-state"
CONF="/data/adb/dnscrypt-proxy-android.conf"
LOG="/data/adb/dnscrypt-proxy.log"

CONFIG="$DATA_DIR/dnscrypt-proxy.toml"
BLOCKLIST="$DATA_DIR/blocked-names.txt"
LAST_UPDATE_FILE="$DATA_DIR/.last_update"
SYNC_FILES="dnscrypt-proxy.toml custom-blocked-names.txt allowed-names.txt allowed-ips.txt blocked-ips.txt"

DNSCRYPT_BIN="$MODDIR/system/bin/dnscrypt-proxy"
MODPROP="$MODDIR/module.prop"
WEBROOT="$MODDIR/webroot"

DAEMON_PIDFILE="$STATE_DIR/daemon.pid"
WATCHDOG_PIDFILE="$STATE_DIR/watchdog.pid"
HEALTH_FILE="$STATE_DIR/health"
HTTPD_PIDFILE="$STATE_DIR/httpd.pid"
UPDATE_PIDFILE="$STATE_DIR/update.pid"
BLCOUNT_CACHE="$STATE_DIR/blocklist_count"
ACTION_LOG="/data/adb/dnscrypt-action.log"
OWNER_FLAG_FILE="$STATE_DIR/owner_match_unavailable"

LISTEN_ADDR="127.0.0.1"
LISTEN_PORT=5354
METRICS_URL="http://127.0.0.1:5555/api/metrics"

# ── Tools ────────────────────────────────────────────────────────────────────
BB=""
for _b in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
  if [ -x "$_b" ]; then BB="$_b"; break; fi
done
unset _b

# ── Settings ─────────────────────────────────────────────────────────────────
# /data/adb/dnscrypt-proxy-android.conf used to be sourced with `.`, which
# executes whatever is in it. It is now parsed: only known keys, only plain
# values. A typo or a stray command in the file can no longer run as root
# inside the watchdog, it is simply ignored.
SETTINGS_KEYS="IP_MODE IPV6_KILL IPV6_PER_IFACE_ENFORCE QUIC_BLOCK LOG_KEEP_LINES HEALTH_RESTART BLOCKLIST_SOURCES BLOCKLIST_AUTO"

load_settings() {
  IP_MODE=""
  IPV6_KILL=1
  IPV6_PER_IFACE_ENFORCE=0
  QUIC_BLOCK=1
  LOG_KEEP_LINES=1500
  HEALTH_RESTART=1
  BLOCKLIST_SOURCES="oisd-big"
  BLOCKLIST_AUTO="off"
  [ -f "$CONF" ] || return 0
  while IFS='=' read -r _k _v || [ -n "$_k" ]; do
    case "$_k" in '' | \#*) continue ;; esac
    _v=${_v%%#*}
    _v=${_v%%[ 	]*}
    _v=${_v#\"}
    _v=${_v%\"}
    case "$_v" in '' | *[!A-Za-z0-9._,-]*) continue ;; esac
    case " $SETTINGS_KEYS " in
      *" $_k "*) eval "$_k=\$_v" ;;
    esac
  done < "$CONF"
  unset _k _v
  # IP_MODE replaced IPV6_KILL in r14. A settings file from before keeps
  # meaning what it meant: IPV6_KILL=0 ("leave IPv6 alone") is dual stack.
  case "$IP_MODE" in
    ipv4 | compat | dual) : ;;
    *) if [ "$IPV6_KILL" = "0" ]; then IP_MODE=dual; else IP_MODE=ipv4; fi ;;
  esac
  return 0
}

# Write one setting, keeping the rest of the file (and its comments) as is.
# The caller validates the value; this only refuses what the parser above
# would ignore anyway.
set_setting() { # <KEY> <VALUE>
  case " $SETTINGS_KEYS " in *" $1 "*) : ;; *) return 1 ;; esac
  case "$2" in '' | *[!A-Za-z0-9._,-]*) return 1 ;; esac
  [ -f "$CONF" ] || : > "$CONF"
  if grep -q "^$1=" "$CONF" 2>/dev/null; then
    sed -i "s|^$1=.*|$1=$2|" "$CONF"
  else
    printf '\n%s=%s\n' "$1" "$2" >> "$CONF"
  fi
}

# ── Time ─────────────────────────────────────────────────────────────────────
# Seconds since boot, for every interval the module measures.
#
# r12 used `date +%s`, and the wall clock is not trustworthy at boot: until
# the network time sync it can be hours, days or decades off, and then it
# jumps. A daemon started before the jump showed an uptime of 20,718 days,
# and the 90-second failsafe deadline could be pushed out indefinitely by a
# backwards jump. /proc/uptime only ever moves forward, at one second per
# second, whatever the clock does.
mono_now() {
  read -r _u _r < /proc/uptime 2>/dev/null
  echo "${_u%%.*}"
  unset _u _r
}

# Centiseconds since boot - for latency measurements, 10 ms resolution.
cs_now() {
  read -r _u _r < /proc/uptime 2>/dev/null
  _s=${_u%%.*}; _f=${_u#*.}
  case "$_f" in ?) _f="${_f}0" ;; esac
  echo "$((_s * 100 + ${_f#0}))"
  unset _u _r _s _f
}

# ── Pause ────────────────────────────────────────────────────────────────────
# "Pause protection" takes the DNS redirect down for a while - for a hotel
# or airport Wi-Fi login page, which only works with the network's own DNS.
# Stored as a deadline in seconds-since-boot, so a reboot always ends it
# (post-fs-data also deletes the file).
PAUSE_FILE="$STATE_DIR/paused_until"

pause_left() {
  _pu=0
  [ -f "$PAUSE_FILE" ] && read -r _pu < "$PAUSE_FILE" 2>/dev/null
  case "$_pu" in '' | *[!0-9]*) _pu=0 ;; esac
  _pl=$((_pu - $(mono_now)))
  [ "$_pl" -lt 0 ] && _pl=0
  echo "$_pl"
  unset _pu _pl
}
is_paused() { [ -f "$PAUSE_FILE" ] && [ "$(pause_left)" -gt 0 ]; }

# ── sdcard mirror ────────────────────────────────────────────────────────────
# After the module itself changes a file in $DATA_DIR, copy it to the
# sdcard mirror and give both the same mtime, so the watchdog's next sync
# does not mistake the module's own write for a user edit.
mirror_to_sd() { # <file name in DATA_DIR>
  [ -f "$DATA_DIR/$1" ] || return 1
  mkdir -p "$SD_DIR" 2>/dev/null || return 1
  cp -f "$DATA_DIR/$1" "$SD_DIR/$1" 2>/dev/null || return 1
  touch -r "$SD_DIR/$1" "$DATA_DIR/$1" 2>/dev/null
}

# ── Logging ──────────────────────────────────────────────────────────────────
# One format for every line the module writes, so the WebUI can filter by
# level. The daemon's own lines ("[2026-..] [NOTICE] ...") share the file.
_ts() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null; }
log_info()  { echo "$(_ts) [INFO] $*"  >> "$LOG"; }
log_warn()  { echo "$(_ts) [WARN] $*"  >> "$LOG"; }
log_error() { echo "$(_ts) [ERROR] $*" >> "$LOG"; }

# Truncate in place, never mv: the daemon holds the log open with O_APPEND
# and would keep writing into an unlinked inode.
rotate_log() {
  [ -f "$LOG" ] || return 0
  _keep=${LOG_KEEP_LINES:-1500}
  case "$_keep" in '' | *[!0-9]*) _keep=1500 ;; esac
  [ "$_keep" -lt 100 ] && _keep=100
  _lines=$(wc -l < "$LOG" 2>/dev/null)
  _lines=$((_lines + 0))
  if [ "$_lines" -gt $((_keep * 2)) ]; then
    tail -n "$_keep" "$LOG" > "$LOG.tmp" 2>/dev/null && cat "$LOG.tmp" > "$LOG" 2>/dev/null
    rm -f "$LOG.tmp"
  fi
  unset _keep _lines
}

# ── Files ────────────────────────────────────────────────────────────────────
mtime_of() { stat -c %Y "$1" 2>/dev/null || echo 0; }

# Domains in blocked-names.txt, not counting comments and blank lines.
# Counting a 7 MB file takes a moment, so the answer is cached against the
# file's mtime and size and only recounted when the file really changed.
blocklist_domains() {
  [ -f "$BLOCKLIST" ] || { echo 0; return 0; }
  # "v2": counts made before r13.1 included comment lines; never reuse them.
  _stamp="v2:$(mtime_of "$BLOCKLIST"):$(stat -c %s "$BLOCKLIST" 2>/dev/null)"
  if [ "$(head -n 1 "$BLCOUNT_CACHE" 2>/dev/null)" = "$_stamp" ]; then
    sed -n 2p "$BLCOUNT_CACHE"
  else
    _cnt=$(grep -cvE '^(#|$)' "$BLOCKLIST" 2>/dev/null)
    _cnt=$((_cnt + 0))
    printf '%s\n%s\n' "$_stamp" "$_cnt" > "$BLCOUNT_CACHE" 2>/dev/null
    echo "$_cnt"
  fi
  unset _stamp _cnt
}

# ── Rules ────────────────────────────────────────────────────────────────────
# If rules.sh is missing, fail open rather than calling undefined functions
# on every tick. No redirect is a worse privacy outcome, but a watchdog
# spewing "not found" is a worse everything outcome.
if [ -f "$MODDIR/sh/rules.sh" ]; then
  # shellcheck source=/dev/null
  . "$MODDIR/sh/rules.sh"
  RULES_OK=1
else
  RULES_OK=0
  rules_flush_all()    { :; }
  rules_install_dns()  { :; }
  rules_remove_dns()   { :; }
  rules_install_quic() { :; }
  rules_remove_quic()  { :; }
  rules_dns_present()  { return 0; }
fi

# ── Process helpers ──────────────────────────────────────────────────────────
# Matched on /proc/PID/comm, not cmdline: the watchdog's own cmdline
# contains "dnscrypt-proxy-android/service.sh" and would match a grep.
daemon_pid() {
  _p=$(cat "$DAEMON_PIDFILE" 2>/dev/null)
  if [ -n "$_p" ] && [ "$(cat "/proc/$_p/comm" 2>/dev/null)" = "dnscrypt-proxy" ]; then
    echo "$_p"; unset _p; return 0
  fi
  _p=$(pidof dnscrypt-proxy 2>/dev/null)
  _p=${_p%% *}
  if [ -n "$_p" ]; then echo "$_p"; unset _p; return 0; fi
  unset _p
  return 1
}

watchdog_pid() {
  _p=$(cat "$WATCHDOG_PIDFILE" 2>/dev/null)
  if [ -n "$_p" ] && tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null | grep -q 'service\.sh'; then
    echo "$_p"; unset _p; return 0
  fi
  unset _p
  return 1
}

# Stop the daemon and make sure it is gone, including any copy that is not
# ours (a previous module version still holding the port).
stop_daemon() {
  _p=$(daemon_pid)
  [ -n "$_p" ] && kill "$_p" 2>/dev/null
  pkill -x dnscrypt-proxy 2>/dev/null
  _i=0
  while [ "$_i" -lt 5 ] && pidof dnscrypt-proxy >/dev/null 2>&1; do
    sleep 1
    _i=$((_i + 1))
  done
  pkill -9 -x dnscrypt-proxy 2>/dev/null
  rm -f "$DAEMON_PIDFILE"
  unset _p _i
}

# Reload the lists with SIGHUP and CONFIRM it happened.
#
# Up to r12 the module sent the signal and assumed it worked. The daemon
# answers a real reload with "Received SIGHUP signal, reloading
# configurations" in the log, so wait for that line. Returns 0 when it was
# confirmed, 1 when the daemon never acknowledged it, 2 when there was no
# daemon to signal. Callers decide what to do about 1 - normally a restart,
# which reads every list from scratch.
reload_daemon() {
  pidof dnscrypt-proxy >/dev/null 2>&1 || return 2
  _before=$(wc -l < "$LOG" 2>/dev/null)
  _before=$((_before + 0))
  pkill -HUP -x dnscrypt-proxy 2>/dev/null
  _i=0
  while [ "$_i" -lt 8 ]; do
    sleep 1
    if tail -n +"$((_before + 1))" "$LOG" 2>/dev/null | grep -q 'Received SIGHUP'; then
      unset _before _i
      return 0
    fi
    _i=$((_i + 1))
  done
  unset _before _i
  return 1
}

# Is a blocklist download running right now?
update_running() {
  _p=$(cat "$UPDATE_PIDFILE" 2>/dev/null)
  [ -n "$_p" ] || { unset _p; return 1; }
  if tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null | grep -q 'update-blocklist'; then
    unset _p; return 0
  fi
  unset _p
  return 1
}

# ── Listener ─────────────────────────────────────────────────────────────────
# /proc/net first: always present, no tool dependency. The local address is
# column 2; pinning the match there stops 14EA (5354) matching a remote port
# or address bytes. udp6/tcp6 are included for the dual-stack listener.
is_listening() {
  for _t in udp tcp udp6 tcp6; do
    if awk 'NR>1 && $2 ~ /:14EA$/ {f=1; exit} END {exit !f}' "/proc/net/$_t" 2>/dev/null; then
      unset _t; return 0
    fi
  done
  unset _t
  if command -v ss >/dev/null 2>&1; then
    ss -uln 2>/dev/null | grep -q ":$LISTEN_PORT " && return 0
    ss -tln 2>/dev/null | grep -q ":$LISTEN_PORT " && return 0
  fi
  return 1
}

has_live_interface() {
  for _if in /sys/class/net/*; do
    [ "${_if##*/}" = "lo" ] && continue
    if [ "$(cat "$_if/operstate" 2>/dev/null)" = "up" ]; then unset _if; return 0; fi
  done
  unset _if
  return 1
}

# ── DNS probes ───────────────────────────────────────────────────────────────
# Raw DNS packets, written with octal escapes because \x is not portable
# across mksh / toybox printf / ash. Sent straight to :5354, so no probe
# depends on the NAT redirect being installed.
#
# Two different questions, because they answer two different things:
#
#   liveness   dnscrypt-probe.invalid A. .invalid is an undelegated TLD, and
#              with block_undelegated = true (the module default) the daemon
#              answers it itself, instantly, without touching the network.
#              Any reply at all means the daemon is alive. No reply means it
#              is hung - and that is true whether or not there is internet.
#
#   resolution example.com A. Needs a working upstream. Tells "protected and
#              working" apart from "running, but nothing gets resolved".
#
# Up to r11 only the second existed, and it only ran at startup, so a daemon
# that held the port but stopped answering was never restarted.
_pkt_live()    { printf '\253\316\001\000\000\001\000\000\000\000\000\000\016dnscrypt-probe\007invalid\000\000\001\000\001'; }
_pkt_resolve() { printf '\253\315\001\000\000\001\000\000\000\000\000\000\007example\003com\000\000\001\000\001'; }

PROBE_TOOL=""
PROBE_NS=""
PROBE_PROVEN=0
PROBE_CANDIDATES="-"
Q_LEN=0
PROBE_COUNT_FILE="$STATE_DIR/probe_queries"

# Every probe is a real query, and dnscrypt-proxy counts it in its totals.
# Keep a tally since the daemon started, so the dashboard can subtract the
# module's own traffic. start_daemon resets it. read/echo only: no spawns.
_count_probe() {
  _pc=0
  [ -f "$PROBE_COUNT_FILE" ] && read -r _pc < "$PROBE_COUNT_FILE" 2>/dev/null
  case "$_pc" in '' | *[!0-9]*) _pc=0 ;; esac
  echo $((_pc + 1)) > "$PROBE_COUNT_FILE" 2>/dev/null
  unset _pc
}

_nc_query() { # <tool> <packet-fn> <wait-seconds>
  case "$1" in
    bbnc) "$2" | "$BB" nc -u -w "$3" "$LISTEN_ADDR" "$LISTEN_PORT" 2>/dev/null | wc -c ;;
    nc)   "$2" | nc -u -w "$3" "$LISTEN_ADDR" "$LISTEN_PORT" 2>/dev/null | wc -c ;;
    *)    echo 0 ;;
  esac
}

# Only netcats that can do UDP. Minimal busybox builds ship an nc without
# -u; piping into one of those produces nothing, which would otherwise read
# exactly like a daemon that stopped answering. Worked out once per process.
# toybox and full busybox list -u under --help; other builds only under -h.
_nc_has_udp() {
  { "$@" --help; "$@" -h; } 2>&1 | grep -q -e ' -u' -e 'UDP'
}

_probe_candidates() {
  [ "$PROBE_CANDIDATES" != "-" ] && return 0
  PROBE_CANDIDATES=""
  if [ -n "$BB" ] && _nc_has_udp "$BB" nc; then
    PROBE_CANDIDATES="bbnc"
  fi
  if command -v nc >/dev/null 2>&1 && _nc_has_udp nc; then
    PROBE_CANDIDATES="$PROBE_CANDIDATES nc"
  fi
  return 0
}

# Sets Q_LEN to the size of the reply (0 = silence). Returns 1 when there is
# no UDP-capable tool at all. Once a tool has produced a reply it is kept
# for the rest of the session, so a hung daemon costs one timeout, not two.
dns_query() { # <packet-fn> <wait-seconds>
  Q_LEN=0
  if [ -n "$PROBE_TOOL" ]; then
    _tools=$PROBE_TOOL
  else
    _probe_candidates
    _tools=$PROBE_CANDIDATES
  fi
  if [ -z "$_tools" ]; then unset _tools; return 1; fi
  for _t in $_tools; do
    _n=$(_nc_query "$_t" "$1" "$2")
    _n=$((_n + 0))
    # A tool that has worked before did send the packet, reply or not.
    if [ "$_n" -gt 0 ] || [ "$PROBE_PROVEN" -eq 1 ]; then _count_probe; fi
    if [ "$_n" -gt 0 ]; then
      Q_LEN=$_n
      PROBE_TOOL=$_t
      PROBE_PROVEN=1
      break
    fi
  done
  unset _tools _t _n
  return 0
}

# Silence only counts as silence once the tool has been seen to work.
# Before that, "no reply" may just as well be the tool, and a daemon must
# never be restarted on the strength of a probe that was never proven.
_silent_or_unknown() {
  if [ "$PROBE_PROVEN" -eq 1 ]; then echo silent; else echo unknown; fi
}

# LIVENESS = ok | silent | unknown
probe_liveness() {
  if dns_query _pkt_live 1; then
    if [ "$Q_LEN" -ge 12 ]; then LIVENESS=ok; else LIVENESS=$(_silent_or_unknown); fi
  else
    LIVENESS=unknown
  fi
}

# RESOLVING = ok | noanswer | silent | unknown
#   ok        a reply larger than the 29-byte question: it carries an answer
#   noanswer  a reply, but no answer in it (SERVFAIL / upstream unreachable)
#   silent    no reply at all, from a probe that has worked before
#   unknown   nothing on this device can ask, or the tool was never proven
probe_resolution() {
  if dns_query _pkt_resolve 3; then
    if [ "$Q_LEN" -gt 29 ]; then
      RESOLVING=ok
    elif [ "$Q_LEN" -gt 0 ]; then
      RESOLVING=noanswer
    else
      RESOLVING=$(_silent_or_unknown)
    fi
    return 0
  fi
  # No UDP netcat anywhere. nslookup goes to :53, so this path relies on
  # the redirect, and it can only say yes or "could not tell".
  _count_probe
  if [ -n "$BB" ] && "$BB" nslookup example.com 127.0.0.1 >/dev/null 2>&1; then
    RESOLVING=ok; PROBE_NS="busybox nslookup"
  elif command -v nslookup >/dev/null 2>&1 && nslookup example.com 127.0.0.1 >/dev/null 2>&1; then
    RESOLVING=ok; PROBE_NS="nslookup"
  else
    RESOLVING=unknown
  fi
}

probe_label() { echo "${PROBE_TOOL:-${PROBE_NS:-none}}"; }

# Health auto-restart relies on the liveness probe being answered locally,
# which is only true with block_undelegated = true.
undelegated_enabled() {
  grep -qE '^[[:space:]]*block_undelegated[[:space:]]*=[[:space:]]*true' "$CONFIG" 2>/dev/null
}

# ── IP mode ──────────────────────────────────────────────────────────────────
#   ipv4    IPv6 off in the kernel and the firewall, AAAA answers blocked.
#           The strongest setting, and what this module always did.
#   compat  IPv6 on, IPv6 DNS redirected into the proxy, AAAA still
#           blocked - apps keep using IPv4, but an IPv6-only carrier
#           (464XLAT) can bring the connection up.
#   dual    IPv6 on, IPv6 DNS redirected, AAAA answered: full dual stack.
#
# Without IPv6 NAT in the kernel the two IPv6 modes run "limited": IPv6 is
# on, but IPv6 DNS cannot be redirected, so the leak guard drops it and
# apps have to use IPv4 DNS. No leak either way - it just might not work
# on a network that only has IPv6 DNS servers.
IP_MODE_FILE="$STATE_DIR/ip_mode_applied"

# The mode the system is actually in right now (what apply_ip_mode did).
ip_mode_applied() {
  _m=""
  [ -f "$IP_MODE_FILE" ] && read -r _m < "$IP_MODE_FILE" 2>/dev/null
  echo "${_m:-none}"
  unset _m
}

_sysctl_w() { [ -w "$1" ] && echo "$2" 2>/dev/null > "$1"; return 0; }

ip6_stack_off() {
  resetprop net.ipv6.conf.all.disable_ipv6 1 2>/dev/null
  resetprop net.ipv6.conf.default.disable_ipv6 1 2>/dev/null
  resetprop net.ipv6.conf.all.accept_redirects 0 2>/dev/null
  resetprop net.ipv6.conf.default.accept_redirects 0 2>/dev/null
  resetprop net.ipv6.conf.lo.disable_ipv6 1 2>/dev/null
  _sysctl_w /proc/sys/net/ipv6/conf/all/disable_ipv6 1
  _sysctl_w /proc/sys/net/ipv6/conf/default/disable_ipv6 1
  _sysctl_w /proc/sys/net/ipv6/conf/all/accept_ra 0
  _sysctl_w /proc/sys/net/ipv6/conf/default/accept_ra 0
  ip6tables -P INPUT   DROP 2>/dev/null
  ip6tables -P OUTPUT  DROP 2>/dev/null
  ip6tables -P FORWARD DROP 2>/dev/null
  ip6tables -C INPUT  -i lo -j ACCEPT 2>/dev/null || ip6tables -A INPUT  -i lo -j ACCEPT 2>/dev/null
  ip6tables -C OUTPUT -o lo -j ACCEPT 2>/dev/null || ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null
}

# Back to kernel defaults. Writing conf/all propagates to every interface,
# loopback included, which is what brings ::1 back for the v6 listener.
ip6_stack_on() {
  for _p in all.disable_ipv6 default.disable_ipv6 all.accept_redirects default.accept_redirects lo.disable_ipv6; do
    resetprop --delete "net.ipv6.conf.$_p" 2>/dev/null
  done
  unset _p
  _sysctl_w /proc/sys/net/ipv6/conf/all/disable_ipv6 0
  _sysctl_w /proc/sys/net/ipv6/conf/default/disable_ipv6 0
  _sysctl_w /proc/sys/net/ipv6/conf/lo/disable_ipv6 0
  _sysctl_w /proc/sys/net/ipv6/conf/all/accept_ra 1
  _sysctl_w /proc/sys/net/ipv6/conf/default/accept_ra 1
  ip6tables -P INPUT   ACCEPT 2>/dev/null
  ip6tables -P OUTPUT  ACCEPT 2>/dev/null
  ip6tables -P FORWARD ACCEPT 2>/dev/null
  ip6tables -D INPUT  -i lo -j ACCEPT 2>/dev/null
  ip6tables -D OUTPUT -o lo -j ACCEPT 2>/dev/null
}

# Make the two toml keys the IP mode owns say what the mode needs.
# Returns 0 when the file was changed (the daemon must restart), 1 when
# it already matched. The sdcard mirror gets the same content and the same
# mtime, so the next sync does not take it for a user edit.
toml_apply_ip_mode() { # <v6 listener 0|1> <block_ipv6 true|false>
  [ -f "$CONFIG" ] || return 1
  if [ "$1" = "1" ]; then
    _la="listen_addresses = ['127.0.0.1:5354', '[::1]:5354']"
  else
    _la="listen_addresses = ['127.0.0.1:5354']"
  fi
  _b6="block_ipv6 = $2"
  _changed=1
  if [ "$(grep -m1 '^listen_addresses' "$CONFIG")" != "$_la" ] || \
     [ "$(grep -m1 '^block_ipv6' "$CONFIG")" != "$_b6" ]; then
    sed -i "s|^listen_addresses[[:space:]]*=.*|$_la|; s|^block_ipv6[[:space:]]*=.*|$_b6|" "$CONFIG"
    mirror_to_sd dnscrypt-proxy.toml
    _changed=0
  fi
  unset _la _b6
  return $_changed
}

# Put the system into $IP_MODE. Idempotent; safe at boot (no daemon yet)
# and at runtime. Sets APPLY_RESTART=1 when the daemon has to restart to
# pick up a changed listener or AAAA setting - the caller does that, since
# only the caller knows whether it owns the daemon.
#
# Order matters. Enabling IPv6: kernel first, so ::1 exists before the
# daemon is asked to listen on it (binding a missing address kills it).
# Disabling: config first, so the daemon stops listening on ::1 before
# loopback loses it.
apply_ip_mode() {
  APPLY_RESTART=0
  _v6nat=0
  have_ip6_nat && _v6nat=1

  case "$IP_MODE" in
    compat | dual)
      ip6_stack_on
      if [ "$_v6nat" = "1" ]; then
        echo 1 > "$IP6_REDIRECT_FILE"
        _eff=$IP_MODE
      else
        echo 0 > "$IP6_REDIRECT_FILE"
        _eff="$IP_MODE-limited"
      fi
      if [ "$IP_MODE" = "dual" ]; then _blk=false; else _blk=true; fi
      toml_apply_ip_mode "$_v6nat" "$_blk" && APPLY_RESTART=1
      ;;
    *)
      echo 0 > "$IP6_REDIRECT_FILE"
      toml_apply_ip_mode 0 true && APPLY_RESTART=1
      ip6_stack_off
      _eff=ipv4
      ;;
  esac

  # Rules follow the redirect decision; only touch them if the redirect is
  # already in place, i.e. the daemon is (or was) up.
  if iptables -t nat -C OUTPUT -p udp --dport 53 -j DNAT --to-destination "$DNS_REDIR" 2>/dev/null; then
    rules_install_dns
  fi

  _prev=$(ip_mode_applied)
  echo "$_eff" > "$IP_MODE_FILE"
  [ "$_prev" != "$_eff" ] && log_info "IP mode: $_eff (was: $_prev)"
  unset _v6nat _eff _blk _prev
  return 0
}

# ── What kind of network is this? (for the WebUI and a boot hint) ────────────
# A clat interface (v4-<iface>) is Android's 464XLAT: the network is IPv6
# only and IPv4 is translated. Its 192.0.0.x address is not real IPv4.
net_has_ipv4() {
  ip -o -4 addr show scope global 2>/dev/null | grep -v ' v4-' | grep -q 'inet '
}
net_has_ipv6() {
  ip -o -6 addr show scope global 2>/dev/null | grep -q 'inet6 '
}
net_has_clat() {
  for _c in /sys/class/net/v4-*; do
    [ -e "$_c" ] && { unset _c; return 0; }
  done
  unset _c
  return 1
}

# ── Module status line ───────────────────────────────────────────────────────
set_module_status() {
  sed -i "s|Status:.*|Status: $1|" "$MODPROP" 2>/dev/null
}
