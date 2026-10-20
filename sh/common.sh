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
# r22: everything the module keeps lives in ONE folder:
#   /data/adb/dnscrypt-proxy/
#     dnscrypt-proxy.toml   the daemon's config (ipset-arm64 reads it HERE)
#     settings.conf         module settings
#     lists/                rule lists, the built blocklist, sources/ cache
#     resolvers/            public-resolvers.md, relays.md (+ .minisig)
#     logs/                 dnscrypt-proxy.log, action.log
#     state/                runtime files, cleared at boot
#     backup/               toml before the last update, Private DNS record
# The daemon runs from DATA_DIR and resolves relative paths in the toml
# against the toml's folder, so the toml says 'lists/blocked-names.txt'.
# Up to r21 these were spread over /data/adb (see LEGACY_* below and
# layout_migrate).
DATA_DIR="/data/adb/dnscrypt-proxy"
SD_DIR="/storage/emulated/0/dnscrypt-proxy"
LISTS_DIR="$DATA_DIR/lists"
RESOLVERS_DIR="$DATA_DIR/resolvers"
LOGS_DIR="$DATA_DIR/logs"
STATE_DIR="$DATA_DIR/state"
BACKUP_DIR="$DATA_DIR/backup"
CONF="$DATA_DIR/settings.conf"
LOG="$LOGS_DIR/dnscrypt-proxy.log"

CONFIG="$DATA_DIR/dnscrypt-proxy.toml"
BLOCKLIST="$LISTS_DIR/blocked-names.txt"
LAST_UPDATE_FILE="$LISTS_DIR/.last_update"
PREV_PDNS_FILE="$BACKUP_DIR/prev-private-dns"
SYNC_FILES="dnscrypt-proxy.toml custom-blocked-names.txt allowed-names.txt allowed-ips.txt blocked-ips.txt"

# Where a file of the sdcard mirror lives on /data (the mirror is flat).
data_path() { # <name>
  case "$1" in
    dnscrypt-proxy.toml) echo "$CONFIG" ;;
    *) echo "$LISTS_DIR/$1" ;;
  esac
}

# Up to r21.
LEGACY_STATE_DIR="/data/adb/dnscrypt-proxy-state"
LEGACY_CONF="/data/adb/dnscrypt-proxy-android.conf"
LEGACY_LOG="/data/adb/dnscrypt-proxy.log"
LEGACY_ACTION_LOG="/data/adb/dnscrypt-action.log"
LEGACY_PREV_PDNS="/data/adb/dnscrypt-prev-private-dns"

DNSCRYPT_BIN="$MODDIR/system/bin/dnscrypt-proxy"
MODPROP="$MODDIR/module.prop"
WEBROOT="$MODDIR/webroot"

DAEMON_PIDFILE="$STATE_DIR/daemon.pid"
WATCHDOG_PIDFILE="$STATE_DIR/watchdog.pid"
HEALTH_FILE="$STATE_DIR/health"
HTTPD_PIDFILE="$STATE_DIR/httpd.pid"
UPDATE_PIDFILE="$STATE_DIR/update.pid"
BLCOUNT_CACHE="$STATE_DIR/blocklist_count"
ACTION_LOG="$LOGS_DIR/action.log"
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

# iptables / ip6tables always wait for the xtables lock.
# Without -w a command fails at once while netd or another module holds the
# lock. A failed "-C" then reads as "rule missing" and the rule gets
# inserted a second time (seen on the phone: DNSC_HS_FWD jumped to twice).
# The functions below shadow the binaries for every script that sources
# this file; which -w form works is probed once per boot (cache reset by
# post-fs-data.sh). Resolved only once, so sourcing twice cannot make the
# function call itself.
IPT_WAIT_FILE="$STATE_DIR/ipt_wait"
if [ -z "$IPT4_BIN" ]; then
  IPT4_BIN=$(command -v iptables 2>/dev/null)
  case "$IPT4_BIN" in /*) ;; *) IPT4_BIN="" ;; esac
  IPT6_BIN=$(command -v ip6tables 2>/dev/null)
  case "$IPT6_BIN" in /*) ;; *) IPT6_BIN="" ;; esac
  IPT_W="-"
fi

_ipt_wait_init() {
  [ "$IPT_W" != "-" ] && return 0
  if [ -f "$IPT_WAIT_FILE" ]; then
    IPT_W=""
    read -r IPT_W 2>/dev/null < "$IPT_WAIT_FILE"
    return 0
  fi
  [ -n "$IPT4_BIN" ] || { IPT_W=""; return 0; }
  for _iw in "-w 5" "-w"; do
    # shellcheck disable=SC2086
    if "$IPT4_BIN" $_iw -S OUTPUT >/dev/null 2>&1; then
      IPT_W=$_iw
      mkdir -p "$STATE_DIR" 2>/dev/null
      echo "$IPT_W" > "$IPT_WAIT_FILE" 2>/dev/null
      unset _iw
      return 0
    fi
  done
  # Neither form worked (no iptables, or held > 5s): run without -w now,
  # probe again next time instead of caching a guess.
  IPT_W=""; unset _iw
  _ipt_w_retry=1
}

iptables() {
  _ipt_wait_init
  [ -n "$IPT4_BIN" ] || return 127
  # shellcheck disable=SC2086
  "$IPT4_BIN" $IPT_W "$@"
  _ipt_rc=$?
  [ -n "$_ipt_w_retry" ] && { IPT_W="-"; unset _ipt_w_retry; }
  return $_ipt_rc
}

ip6tables() {
  _ipt_wait_init
  [ -n "$IPT6_BIN" ] || return 127
  # shellcheck disable=SC2086
  "$IPT6_BIN" $IPT_W "$@"
  _ipt_rc=$?
  [ -n "$_ipt_w_retry" ] && { IPT_W="-"; unset _ipt_w_retry; }
  return $_ipt_rc
}

# ── Reading the tables without the xtables lock (r17) ────────────────────────
# "iptables -C / -S" can take the global xtables lock. WireGuard's wg-quick
# (and other VPN apps) run iptables WITHOUT -w and fail outright if anyone
# holds the lock at that instant ("wg-quick returned 4" / "124", measured
# with VPN Hotspot Arm64 on the same phone). The watchdog and the WebUI poll
# checked rules with ~20 such calls every few seconds. They now read the
# tables with iptables-save, which never takes the lock; only real changes
# (-I / -A / -D, with -w) still do.
if [ -z "$IPTS4_BIN" ]; then
  IPTS4_BIN=$(command -v iptables-save 2>/dev/null)
  case "$IPTS4_BIN" in /*) ;; *) IPTS4_BIN="" ;; esac
  IPTS6_BIN=$(command -v ip6tables-save 2>/dev/null)
  case "$IPTS6_BIN" in /*) ;; *) IPTS6_BIN="" ;; esac
fi

# ipt_dump <4|6> <table>: the table as "iptables -S" lines (-P/-N/-A).
ipt_dump() {
  if [ "$1" = 6 ]; then _db=$IPTS6_BIN; _dc=ip6tables; else _db=$IPTS4_BIN; _dc=iptables; fi
  if [ -n "$_db" ]; then
    _dt=$("$_db" -t "$2" 2>/dev/null) || { unset _db _dc _dt; return 1; }
    case "$_dt" in *"*$2"*) ;; *) unset _db _dc _dt; return 1 ;; esac
    printf '%s\n' "$_dt" | sed -n -e 's/^:\([^ ]*\) - .*/-N \1/p' -e 's/^:\([^ ]*\) \([A-Z][A-Z]*\) .*/-P \1 \2/p' -e '/^-A /p'
    unset _db _dc _dt
    return 0
  fi
  "$_dc" -t "$2" -S 2>/dev/null; _dr=$?
  unset _db _dc
  return $_dr
}

# One snapshot per watchdog tick / ctl run; anything that writes marks it
# stale so the next check reads again.
SNAP_OK=0
ipt_snap() {
  [ "$SNAP_OK" = 1 ] && return 0
  S4F=$(ipt_dump 4 filter)
  S4N=$(ipt_dump 4 nat)
  if S6F=$(ipt_dump 6 filter) && [ -n "$S6F" ]; then S6OK=1; else S6OK=0; S6F=""; fi
  S6N=$(ipt_dump 6 nat) || S6N=""
  SNAP_OK=1
}
ipt_snap_stale() { SNAP_OK=0; }

# sn_has <dump> <ERE for a whole rule line>
sn_has() { printf '%s\n' "$1" | grep -qE -- "$2"; }
# sn_jumps <dump> <parent> <chain>: number of plain jumps
sn_jumps() { printf '%s\n' "$1" | awk -v j="-A $2 -j $3" '$0 == j { c++ } END { print c + 0 }'; }
# sn_chain <dump> <chain>: chain exists
sn_chain() { printf '%s\n' "$1" | grep -qx -- "-N $2"; }
# sn_count <dump> <chain>: rules in it
sn_count() { printf '%s\n' "$1" | grep -c -- "^-A $2 "; }

# ── Settings ─────────────────────────────────────────────────────────────────
# /data/adb/dnscrypt-proxy-android.conf used to be sourced with `.`, which
# executes whatever is in it. It is now parsed: only known keys, only plain
# values. A typo or a stray command in the file can no longer run as root
# inside the watchdog, it is simply ignored.
SETTINGS_KEYS="IP_MODE IPV6_KILL IPV6_PER_IFACE_ENFORCE QUIC_BLOCK LOG_KEEP_LINES HEALTH_RESTART BLOCKLIST_SOURCES BLOCKLIST_AUTO HOTSPOT_DNS HOTSPOT_DOT"

load_settings() {
  IP_MODE=""
  IPV6_KILL=1
  IPV6_PER_IFACE_ENFORCE=0
  QUIC_BLOCK=1
  LOG_KEEP_LINES=1500
  HEALTH_RESTART=1
  BLOCKLIST_SOURCES="oisd-big"
  BLOCKLIST_AUTO="off"
  HOTSPOT_DNS=0
  HOTSPOT_DOT=0
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
  read -r _u _r 2>/dev/null < /proc/uptime
  echo "${_u%%.*}"
  unset _u _r
}

# Centiseconds since boot - for latency measurements, 10 ms resolution.
cs_now() {
  read -r _u _r 2>/dev/null < /proc/uptime
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
  [ -f "$PAUSE_FILE" ] && read -r _pu 2>/dev/null < "$PAUSE_FILE"
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
mirror_to_sd() { # <file name of the mirror, see data_path>
  _ms=$(data_path "$1")
  [ -f "$_ms" ] || { unset _ms; return 1; }
  mkdir -p "$SD_DIR" 2>/dev/null || { unset _ms; return 1; }
  cp -f "$_ms" "$SD_DIR/$1" 2>/dev/null || { unset _ms; return 1; }
  touch -r "$SD_DIR/$1" "$_ms" 2>/dev/null
  unset _ms
}

# ── r22 layout migration ─────────────────────────────────────────────────────
# Runs at the start of post-fs-data, before anything reads a file. The
# installer only COPIED the old files into the new layout (the old version
# keeps running until the reboot and still uses the old paths), so for every
# old file: the newer of the two wins, then the old one goes. Idempotent -
# after the first boot there is nothing left to move.
_lm_take() { # <old> <new> -> 0 if the old one was taken
  [ -e "$1" ] || return 1
  if [ ! -e "$2" ] || [ "$(mtime_of "$1")" -gt "$(mtime_of "$2")" ]; then
    mkdir -p "${2%/*}" 2>/dev/null
    rm -rf "$2" 2>/dev/null
    mv -f "$1" "$2" 2>/dev/null && return 0
  fi
  rm -rf "$1" 2>/dev/null
  return 1
}

layout_migrate() {
  mkdir -p "$LISTS_DIR" "$RESOLVERS_DIR" "$LOGS_DIR" "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null
  _lm_any=0
  for _lm_p in "$LEGACY_CONF" "$LEGACY_LOG" "$LEGACY_ACTION_LOG" "$LEGACY_PREV_PDNS" \
               "$LEGACY_STATE_DIR" "$LEGACY_CONF.bak" "$DATA_DIR/sources" "$DATA_DIR/blocked-names.txt"; do
    [ -e "$_lm_p" ] && { _lm_any=1; break; }
  done
  [ "$_lm_any" = 1 ] || { unset _lm_any _lm_p; return 0; }

  _lm_took=""
  _lm_take "$LEGACY_CONF" "$CONF" && _lm_took="$_lm_took settings"
  [ -f "$LEGACY_CONF.bak" ] && mv -f "$LEGACY_CONF.bak" "$BACKUP_DIR/settings.conf.bak" 2>/dev/null
  _lm_take "$LEGACY_PREV_PDNS" "$PREV_PDNS_FILE"
  # Logs: the old one is the history - keep it in front of anything newer.
  if [ -f "$LEGACY_LOG" ]; then
    [ -f "$LOG" ] && cat "$LOG" >> "$LEGACY_LOG" 2>/dev/null
    mv -f "$LEGACY_LOG" "$LOG" 2>/dev/null && _lm_took="$_lm_took log"
  fi
  if [ -f "$LEGACY_ACTION_LOG" ]; then
    [ -f "$ACTION_LOG" ] && cat "$ACTION_LOG" >> "$LEGACY_ACTION_LOG" 2>/dev/null
    mv -f "$LEGACY_ACTION_LOG" "$ACTION_LOG" 2>/dev/null
  fi
  # Runtime state is rebuilt every boot anyway.
  rm -rf "$LEGACY_STATE_DIR" 2>/dev/null

  # Lists and blocklist metadata, flat in DATA_DIR up to r21.
  for _lm_f in allowed-names.txt allowed-ips.txt blocked-ips.txt custom-blocked-names.txt \
               blocked-names.txt custom-sources.txt .last_update .last_update_epoch \
               .last_update_attempt .last_update_report .custom.merged; do
    _lm_take "$DATA_DIR/$_lm_f" "$LISTS_DIR/$_lm_f" && _lm_took="$_lm_took $_lm_f"
  done
  # The download cache: the installer leaves it where it is (it is big and
  # only an update touches it), so the old folder is the current one.
  if [ -d "$DATA_DIR/sources" ]; then
    rm -rf "$LISTS_DIR/sources" 2>/dev/null
    mv -f "$DATA_DIR/sources" "$LISTS_DIR/sources" 2>/dev/null && _lm_took="$_lm_took sources/"
  fi
  # Module-owned files: the installer put fresh copies in place.
  for _lm_f in public-resolvers.md public-resolvers.md.minisig relays.md relays.md.minisig; do
    _lm_take "$DATA_DIR/$_lm_f" "$RESOLVERS_DIR/$_lm_f"
  done
  for _lm_f in dnscrypt-proxy.toml.before-update dnscrypt-proxy.toml.bak; do
    _lm_take "$DATA_DIR/$_lm_f" "$BACKUP_DIR/$_lm_f"
  done
  rm -f "$DATA_DIR/LICENSE" "$DATA_DIR"/.*.preserve 2>/dev/null

  log_info "files moved into one folder, $DATA_DIR (r22 layout). Taken from the old places:${_lm_took:- nothing newer}"
  unset _lm_any _lm_p _lm_took _lm_f
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
  _lines=$(wc -l 2>/dev/null < "$LOG")
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
  rules_dns_any_present() { return 1; }
  hotspot_sync()       { :; }
  hotspot_teardown()   { :; }
  hotspot_ifaces()     { :; }
  hotspot_ifaces_line() { :; }
  hotspot_clients()    { :; }
fi

# ── Process helpers ──────────────────────────────────────────────────────────
# Every live dnscrypt-proxy, by /proc/PID/comm. Not pidof / pkill -x:
# busybox (KernelSU runs module scripts with its busybox ash) matches -x
# against argv[0], which is the daemon's full path, so `pkill -x
# dnscrypt-proxy` found nothing - reloads never reached the daemon and
# every one of them turned into a restart - while pidof and toybox pgrep
# also report zombies. read/case only: no process spawned per /proc entry.
daemon_pids() {
  for _dd in /proc/[0-9]*; do
    read -r _dc 2>/dev/null < "$_dd/comm" || continue
    [ "$_dc" = "dnscrypt-proxy" ] || continue
    read -r _ds 2>/dev/null < "$_dd/stat" || continue
    case "${_ds##*) }" in Z* | X*) continue ;; esac
    echo "${_dd#/proc/}"
  done
  unset _dd _dc _ds
}
daemon_any() { [ -n "$(daemon_pids)" ]; }
daemon_signal() { # <signal>
  for _sp in $(daemon_pids); do kill "-$1" "$_sp" 2>/dev/null; done
  unset _sp
}

# Matched on /proc/PID/comm, not cmdline: the watchdog's own cmdline
# contains "dnscrypt-proxy-android/service.sh" and would match a grep.
daemon_pid() {
  _p=$(cat "$DAEMON_PIDFILE" 2>/dev/null)
  if [ -n "$_p" ] && [ "$(cat "/proc/$_p/comm" 2>/dev/null)" = "dnscrypt-proxy" ]; then
    echo "$_p"; unset _p; return 0
  fi
  _p=$(daemon_pids)
  _p=${_p%%[!0-9]*}
  if [ -n "$_p" ]; then echo "$_p"; unset _p; return 0; fi
  unset _p
  return 1
}

watchdog_pid() {
  _p=$(cat "$WATCHDOG_PIDFILE" 2>/dev/null)
  if [ -n "$_p" ] && tr '\0' ' ' 2>/dev/null < "/proc/$_p/cmdline" | grep -q 'service\.sh'; then
    echo "$_p"; unset _p; return 0
  fi
  unset _p
  return 1
}

# Stop the daemon and make sure it is gone, including any copy that is not
# ours (a previous module version still holding the port).
# Waits for the processes it signalled, and only for them: the watchdog
# may start a fresh daemon within the same second, and that one must not
# be waited on - or killed - as if it were the old one.
stop_daemon() {
  _sd=$(daemon_pids)
  for _p in $_sd; do kill -TERM "$_p" 2>/dev/null; done
  _i=0
  while [ "$_i" -lt 10 ]; do
    _alive=""
    for _p in $_sd; do
      read -r _st 2>/dev/null < "/proc/$_p/stat" || continue
      case "${_st##*) }" in Z* | X*) continue ;; esac
      _alive="$_alive $_p"
    done
    [ -n "$_alive" ] || break
    sleep 0.5 2>/dev/null || sleep 1
    _i=$((_i + 1))
  done
  for _p in $_alive; do kill -KILL "$_p" 2>/dev/null; done
  rm -f "$DAEMON_PIDFILE"
  unset _sd _p _i _alive _st
  wake_watchdog
}

# The watchdog sleeps 10s between ticks. When ctl.sh stops the daemon for a
# restart, an IP mode switch or new resolvers, it wakes the watchdog so the
# daemon is back in a second instead of after up to ten. Only a watchdog
# that registered itself in $WATCHDOG_WAKE (and so traps USR1) is woken:
# to a watchdog without the trap, USR1 would be fatal.
WATCHDOG_WAKE="$STATE_DIR/watchdog.wake"
wake_watchdog() {
  _wp=$(cat "$WATCHDOG_WAKE" 2>/dev/null)
  [ -n "$_wp" ] && [ "$_wp" != "$$" ] && [ "$_wp" = "$(watchdog_pid)" ] && kill -USR1 "$_wp" 2>/dev/null
  unset _wp
  return 0
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
  daemon_any || return 2
  _before=$(wc -l 2>/dev/null < "$LOG")
  _before=$((_before + 0))
  daemon_signal HUP
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
#
# Starting one is not instant: the spawner forks, the child execs setsid,
# setsid execs sh, and only then does /proc/PID/cmdline say
# update-blocklist. A poll that landed in that window got "not running"
# and the WebUI stopped following an update that had just started. So
# the spawner leaves a pending marker (its time, seconds since boot)
# before it forks; the worker removes it once its pid file is written.
# A marker older than 20s belongs to a worker that died at birth.
UPDATE_PENDING="$STATE_DIR/update.pending"

update_running() {
  _p=$(cat "$UPDATE_PIDFILE" 2>/dev/null)
  if [ -n "$_p" ] && tr '\0' ' ' 2>/dev/null < "/proc/$_p/cmdline" | grep -q 'update-blocklist'; then
    unset _p; return 0
  fi
  unset _p
  if [ -f "$UPDATE_PENDING" ]; then
    _p=$(cat "$UPDATE_PENDING" 2>/dev/null)
    case "$_p" in '' | *[!0-9]*) _p=0 ;; esac
    if [ $(( $(mono_now) - _p )) -lt 20 ]; then unset _p; return 0; fi
    rm -f "$UPDATE_PENDING"
    unset _p
  fi
  return 1
}

# Start update-blocklist.sh fully detached. Its own session, no inherited
# stdio: the root manager's exec waits for stdout to close, so anything
# still holding it would freeze the WebUI until the download finished.
start_update_worker() { # [--auto]
  mkdir -p "$STATE_DIR"
  mono_now > "$UPDATE_PENDING"
  # The worker writes its own pid. $! is not written here: when setsid has
  # to fork (it does if it starts as a process-group leader), $! is the
  # short-lived setsid, and writing it after the worker wrote its pid
  # would make a running update look finished.
  setsid sh "$MODDIR/update-blocklist.sh" "$@" < /dev/null > "$ACTION_LOG" 2>&1 &
}

# ── Listener ─────────────────────────────────────────────────────────────────
# /proc/net first: always present, no tool dependency. The local address is
# column 2; pinning the match there stops 14EA (5354) matching a remote port
# or address bytes. udp6/tcp6 are included for the dual-stack listener.
# Column 4 is the socket state, and only a listener counts: 0A (LISTEN) for
# TCP, 07 (unconnected) for UDP. r12 took any socket with local port 5354,
# and the server side of a finished DNS-over-TCP query sits in TIME_WAIT
# on that port for a minute after the daemon is gone - so a restart could
# be reported as done before the new daemon had even started.
is_listening() {
  for _t in udp tcp udp6 tcp6; do
    if awk 'NR>1 && $2 ~ /:14EA$/ && ($4 == "0A" || $4 == "07") {f=1; exit} END {exit !f}' "/proc/net/$_t" 2>/dev/null; then
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

# A network is up. First Android's own answer: its default network (the
# "fwmark 0x0/0xffff iif lo lookup X" rule, see net_default_iface). Mobile
# data (rmnet_*, ccmni*) and tunnels report operstate "unknown", never "up",
# so the operstate test alone said "no interface up" on mobile data with
# Wi-Fi off (r23). It stays as the fallback for when the rule is not there.
has_live_interface() {
  _dn=$(net_default_iface)
  if [ -n "$_dn" ] && [ -d "/sys/class/net/$_dn" ]; then unset _dn; return 0; fi
  unset _dn
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
  [ -f "$PROBE_COUNT_FILE" ] && read -r _pc 2>/dev/null < "$PROBE_COUNT_FILE"
  case "$_pc" in '' | *[!0-9]*) _pc=0 ;; esac
  echo $((_pc + 1)) > "$PROBE_COUNT_FILE" 2>/dev/null
  unset _pc
}

# How to make a UDP netcat stop waiting for the reply. The two netcats on
# a rooted phone disagree about -w:
#   busybox nc   -w SEC  "timeout for connects and final net reads"
#   toybox nc    -w SEC  connect timeout only. A UDP "connection" never
#                        closes, so after the reply (or none) it waits
#                        forever. Its -q SEC ("quit SEC after EOF on
#                        stdin") is what ends it.
# r12 passed -w to both: with Android's own nc as the only UDP-capable
# tool, the first probe never returned and the watchdog stopped ticking.
# The flag is chosen from the tool's own help, and `timeout` (toybox and
# busybox both have it) is a second guard around every probe.
_nc_wait_flag() { # <nc command...> -> q or w
  if { "$@" --help; "$@" -h; } 2>&1 | grep -qE '^[[:space:]]*-q[[:space:]]'; then echo q; else echo w; fi
}
NC_FLAG_bbnc=""
NC_FLAG_nc=""

_nc_run() { # <wait> <nc command...>   stdin: packet, stdout: reply
  _w=$1; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$((_w + 2))" "$@" 2>/dev/null
  else
    "$@" 2>/dev/null
  fi
}

_nc_query() { # <tool> <packet-fn> <wait-seconds>
  case "$1" in
    bbnc)
      [ -n "$NC_FLAG_bbnc" ] || NC_FLAG_bbnc=$(_nc_wait_flag "$BB" nc)
      "$2" | _nc_run "$3" "$BB" nc -u "-$NC_FLAG_bbnc" "$3" "$LISTEN_ADDR" "$LISTEN_PORT" | wc -c ;;
    nc)
      [ -n "$NC_FLAG_nc" ] || NC_FLAG_nc=$(_nc_wait_flag nc)
      "$2" | _nc_run "$3" nc -u "-$NC_FLAG_nc" "$3" "$LISTEN_ADDR" "$LISTEN_PORT" | wc -c ;;
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
    # The packet was sent whether or not a reply came back (the tool was
    # checked for UDP support), and dnscrypt-proxy counts it either way.
    # r12 only counted unanswered probes once the tool had been proven, so
    # the queries of a daemon still starting up stayed in the totals.
    _count_probe
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
probe_resolution() { # [wait-seconds, default 3]
  if dns_query _pkt_resolve "${1:-3}"; then
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
#   ipv4    IPv6 blocked by the firewall (DROP policy), AAAA answers
#           blocked. Since r22 only the carrier's service networks (IMS =
#           VoLTE, MMS, emergency) keep IPv6 - see v6c_sync.
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
  [ -f "$IP_MODE_FILE" ] && read -r _m 2>/dev/null < "$IP_MODE_FILE"
  echo "${_m:-none}"
  unset _m
}

_sysctl_w() { [ -w "$1" ] && echo "$2" 2>/dev/null > "$1"; return 0; }
_sysctl_r() { _sr=""; [ -r "$1" ] && read -r _sr 2>/dev/null < "$1"; echo "$_sr"; unset _sr; }

# Kernel IPv6 back to its defaults. Writing conf/all propagates to every
# interface, loopback included, which is what brings ::1 back for the v6
# listener and undoes per-interface IPv6 off (IPV6_PER_IFACE_ENFORCE).
ip6_kernel_on() {
  for _p in all.disable_ipv6 default.disable_ipv6 all.accept_redirects default.accept_redirects lo.disable_ipv6; do
    resetprop --delete "net.ipv6.conf.$_p" 2>/dev/null
  done
  unset _p
  _sysctl_w /proc/sys/net/ipv6/conf/all/disable_ipv6 0
  _sysctl_w /proc/sys/net/ipv6/conf/default/disable_ipv6 0
  _sysctl_w /proc/sys/net/ipv6/conf/lo/disable_ipv6 0
  _sysctl_w /proc/sys/net/ipv6/conf/all/accept_ra 1
  _sysctl_w /proc/sys/net/ipv6/conf/default/accept_ra 1
  # IPv4-only mode before r22 set default/accept_ra=0, so every mobile data
  # interface created meanwhile kept 0 and never takes the carrier's IPv6
  # again (Wi-Fi is re-armed by Android on each connect, mobile data is
  # not). r17: put the kernel default back on them.
  for _c in /proc/sys/net/ipv6/conf/*; do
    case "${_c##*/}" in rmnet* | ccmni* | seth* | rev_rmnet*) ;; *) continue ;; esac
    [ "$(_sysctl_r "$_c/accept_ra")" = "0" ] && echo 1 2>/dev/null > "$_c/accept_ra"
  done
  unset _c
}

# IPv4 only. Since r22 IPv6 stays ON in the kernel: the carrier's service
# networks (IMS = VoLTE / Wi-Fi calling, MMS, emergency calls) are very
# often IPv6-only, and switching IPv6 off in the kernel took them down -
# no VoLTE, calls fell back to 2G, and mobile data stopped during every
# call. The firewall is the killswitch: ip6tables DROP everywhere, except
# on those carrier service interfaces (DNSC_V6C_IN / DNSC_V6C_OUT, see
# v6c_sync) and for Neighbor Discovery (DNSC_V6ND), which they need to get
# their address. Apps cannot use those networks (Android keeps them for the
# system), and AAAA answers stay blocked, so nothing leaks.
ip6_stack_off() {
  # Coming from r21 or older (or a leftover prop): kernel IPv6 was off.
  # Only written when needed - a write to conf/all touches every interface.
  if [ "$(_sysctl_r /proc/sys/net/ipv6/conf/all/disable_ipv6)" = "1" ] || \
     [ "$(_sysctl_r /proc/sys/net/ipv6/conf/default/disable_ipv6)" = "1" ] || \
     [ "$(_sysctl_r /proc/sys/net/ipv6/conf/default/accept_ra)" = "0" ]; then
    ip6_kernel_on
  fi
  ip6tables -P INPUT   DROP 2>/dev/null
  ip6tables -P OUTPUT  DROP 2>/dev/null
  ip6tables -P FORWARD DROP 2>/dev/null
  ip6tables -C INPUT  -i lo -j ACCEPT 2>/dev/null || ip6tables -A INPUT  -i lo -j ACCEPT 2>/dev/null
  ip6tables -C OUTPUT -o lo -j ACCEPT 2>/dev/null || ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null
  ipt_snap_stale
  v6c_sync force
}

ip6_stack_on() {
  ip6_kernel_on
  v6c_teardown
  ip6tables -P INPUT   ACCEPT 2>/dev/null
  ip6tables -P OUTPUT  ACCEPT 2>/dev/null
  ip6tables -P FORWARD ACCEPT 2>/dev/null
  ip6tables -D INPUT  -i lo -j ACCEPT 2>/dev/null
  ip6tables -D OUTPUT -o lo -j ACCEPT 2>/dev/null
  ipt_snap_stale
}

# ── Carrier service networks in IPv4-only mode (r22) ────────────────────────
# Android lists every network it has in `dumpsys connectivity`, one
# "NetworkAgentInfo{...}" line each. A carrier service network is a
# CELLULAR one (Wi-Fi calling's IWLAN network is CELLULAR too) WITHOUT the
# INTERNET capability and WITH one of IMS / EIMS / MMS / XCAP / RCS.
# Measured on a Poco F6 Pro (Xiaomi.eu, Greek SIM roaming in Bulgaria):
#   InterfaceName: rmnet_data2 ... Capabilities: INTERNET&NOT_RESTRICTED&...   (data, IPv4)
#   InterfaceName: rmnet_data1 ... Capabilities: IMS&NOT_METERED&...&MMTEL&... (VoLTE, IPv6 only)
V6C_IN=DNSC_V6C_IN
V6C_OUT=DNSC_V6C_OUT
# Neighbor Discovery (router solicitation / advertisement, neighbor
# solicitation / advertisement, redirect), every interface. Without the
# router advertisement the IMS interface never gets its global address, so
# Android never brings the IMS network up - and there is nothing to detect
# (measured: after a reboot in IPv4 only no IMS network existed at all;
# with ICMPv6 let through it came up at once). ND never leaves the link
# and carries no app data; hop limit 255 is what RFC 4861 requires of it.
V6ND=DNSC_V6ND
V6ND_TYPES="133 134 135 136 137"
V6C_FILE="$STATE_DIR/v6_carrier"     # line 1: ip rule signature, 2: time, 3: "iface:KIND ..."
V6C_RECHECK=300                      # dumpsys at least this often (s), on top of rule changes

# Parses dumpsys lines on stdin -> "iface:KIND" per line (KIND = first
# carrier capability found).
v6c_parse() {
  while IFS= read -r _l; do
    case "$_l" in *"Transports: CELLULAR"*) ;; *) continue ;; esac
    case "$_l" in *"Capabilities: "*) ;; *) continue ;; esac
    case "$_l" in *"InterfaceName: "*) ;; *) continue ;; esac
    _caps=${_l#*Capabilities: }; _caps=${_caps%% *}
    case "&$_caps&" in *"&INTERNET&"*) continue ;; esac
    _kind=""
    for _k in IMS EIMS MMS XCAP RCS; do
      case "&$_caps&" in *"&$_k&"*) _kind=$_k; break ;; esac
    done
    [ -n "$_kind" ] || continue
    _if=${_l#*InterfaceName: }; _if=${_if%% *}
    case "$_if" in '' | *[!A-Za-z0-9_.@-]*) continue ;; esac
    echo "$_if:$_kind"
  done
  unset _l _caps _kind _k _if
}

v6c_detect() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 10 dumpsys connectivity 2>/dev/null
  else
    dumpsys connectivity 2>/dev/null
  fi | grep '^ *NetworkAgentInfo{' | v6c_parse | sort -u
}

# Cheap change detector, read every tick: netd adds `ip rule` lines for
# every network it creates (lookup <iface>), the IMS one included.
_v6c_sig() {
  ip -6 rule 2>/dev/null | sed -n 's/.* lookup \([^ ]*\).*/\1/p' | sort -u | awk '{ printf "%s ", $0 }'
}

# The cached list ("iface:KIND iface:KIND"), empty when none.
v6c_list() {
  [ -f "$V6C_FILE" ] && sed -n 3p "$V6C_FILE" 2>/dev/null
}

# Make the chains, the jumps and the per-interface ACCEPTs match Android's
# current carrier networks. Every watchdog tick in IPv4-only mode, and from
# ip6_stack_off with "force". Calls dumpsys only when the ip rule signature
# changed, after V6C_RECHECK seconds, on force, or when the chains are off.
# The watchdog and ctl.sh (an IP-mode switch from the WebUI) can both run
# this at the same moment: one flushed the chains while the other filled
# them, and the carrier ACCEPT could be missing until the next tick (seen in
# the harness). A short mkdir lock serialises them; the snapshot is read
# fresh inside it.
V6C_LOCK="$STATE_DIR/v6c.lock"
_v6c_lock() {
  _vl=0
  while ! mkdir "$V6C_LOCK" 2>/dev/null; do
    _vp=""; read -r _vp 2>/dev/null < "$V6C_LOCK/pid"
    # holder gone (killed, crashed): take it over at once
    if [ -n "$_vp" ] && ! kill -0 "$_vp" 2>/dev/null; then rm -rf "$V6C_LOCK"; continue; fi
    _vl=$((_vl + 1))
    if [ "$_vl" -ge 50 ]; then   # ~5 s: holder hung - take it over
      rm -rf "$V6C_LOCK"; mkdir "$V6C_LOCK" 2>/dev/null; break
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done
  echo "$$" > "$V6C_LOCK/pid" 2>/dev/null
  unset _vl _vp
}
_v6c_unlock() { rm -rf "$V6C_LOCK" 2>/dev/null; }

v6c_sync() {
  _v6c_lock
  ipt_snap_stale
  _v6c_sync "$@"
  _vs_rc=$?
  _v6c_unlock
  return $_vs_rc
}

_v6c_sync() {
  _vs_force=${1:-}
  ipt_snap
  [ "$S6OK" = 1 ] || return 0
  _vs_fix=0
  for _vs_c in "$V6ND" "$V6C_IN" "$V6C_OUT"; do
    sn_chain "$S6F" "$_vs_c" || { ip6tables -N "$_vs_c" 2>/dev/null; _vs_fix=1; }
  done
  # Jumps go at the END of INPUT/OUTPUT: netd's accounting and the other
  # modules' chains (ipset-arm64 IPSA_*) still see the packet first; the
  # only thing after us is the DROP policy.
  for _vs_p in "INPUT $V6ND" "OUTPUT $V6ND" "INPUT $V6C_IN" "OUTPUT $V6C_OUT"; do
    set -- $_vs_p
    _vs_n=$(sn_jumps "$S6F" "$1" "$2")
    if [ "$_vs_n" = "0" ]; then
      ip6tables -A "$1" -j "$2" 2>/dev/null; _vs_fix=1
    elif [ "$_vs_n" -gt 1 ] 2>/dev/null; then
      while ip6tables -D "$1" -j "$2" 2>/dev/null; do :; done
      ip6tables -A "$1" -j "$2" 2>/dev/null; _vs_fix=1
    fi
  done
  [ "$_vs_fix" = 1 ] && ipt_snap_stale && ipt_snap

  # ND chain: one ACCEPT per type, with the hop-limit check when the kernel
  # has the hl match (CONFIG_IP6_NF_MATCH_HL), without it otherwise.
  set -- $V6ND_TYPES
  if [ "$(sn_count "$S6F" "$V6ND")" != "$#" ]; then
    ip6tables -F "$V6ND" 2>/dev/null
    for _vs_t in $V6ND_TYPES; do
      ip6tables -A "$V6ND" -p icmpv6 --icmpv6-type "$_vs_t" -m hl --hl-eq 255 -j ACCEPT 2>/dev/null || \
        ip6tables -A "$V6ND" -p icmpv6 --icmpv6-type "$_vs_t" -j ACCEPT 2>/dev/null
    done
    ipt_snap_stale; ipt_snap
  fi

  _vs_sig=$(_v6c_sig)
  _vs_now=$(date +%s)
  _vs_osig=""; _vs_ot=0; _vs_old=""
  if [ -f "$V6C_FILE" ]; then
    _vs_osig=$(sed -n 1p "$V6C_FILE" 2>/dev/null)
    _vs_ot=$(sed -n 2p "$V6C_FILE" 2>/dev/null)
    _vs_old=$(sed -n 3p "$V6C_FILE" 2>/dev/null)
  fi
  case "$_vs_ot" in '' | *[!0-9]*) _vs_ot=0 ;; esac
  _vs_want=$_vs_old
  if [ "$_vs_force" = "force" ] || [ ! -f "$V6C_FILE" ] || [ "$_vs_sig" != "$_vs_osig" ] || \
     [ $((_vs_now - _vs_ot)) -ge "$V6C_RECHECK" ]; then
    if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
      _vs_want=$(v6c_detect | awk '{ printf "%s%s", (NR > 1 ? " " : ""), $0 }')
      printf '%s\n%s\n%s\n' "$_vs_sig" "$_vs_now" "$_vs_want" > "$V6C_FILE" 2>/dev/null
    fi
    # Before boot_completed (post-fs-data: no system_server, and its 10 s
    # budget) nothing is written, so the watchdog asks again next tick.
  fi

  # Chain content = exactly one ACCEPT per wanted interface.
  _vs_exp=""
  for _vs_e in $_vs_want; do _vs_exp="$_vs_exp${_vs_exp:+ }${_vs_e%%:*}"; done
  _vs_have_in=$(printf '%s\n' "$S6F" | sed -n "s/^-A $V6C_IN -i \([^ ]*\) -j ACCEPT\$/\1/p" | sort | awk '{ printf "%s%s", (NR > 1 ? " " : ""), $0 }')
  _vs_have_out=$(printf '%s\n' "$S6F" | sed -n "s/^-A $V6C_OUT -o \([^ ]*\) -j ACCEPT\$/\1/p" | sort | awk '{ printf "%s%s", (NR > 1 ? " " : ""), $0 }')
  _vs_exp_s=$(for _vs_e in $_vs_exp; do echo "$_vs_e"; done | sort | awk '{ printf "%s%s", (NR > 1 ? " " : ""), $0 }')
  if [ "$_vs_have_in" != "$_vs_exp_s" ] || [ "$_vs_have_out" != "$_vs_exp_s" ] || \
     [ "$(sn_count "$S6F" "$V6C_IN")" != "$(sn_count "$S6F" "$V6C_OUT")" ]; then
    ip6tables -F "$V6C_IN" 2>/dev/null
    ip6tables -F "$V6C_OUT" 2>/dev/null
    for _vs_e in $_vs_exp; do
      ip6tables -A "$V6C_IN"  -i "$_vs_e" -j ACCEPT 2>/dev/null
      ip6tables -A "$V6C_OUT" -o "$_vs_e" -j ACCEPT 2>/dev/null
      # IPV6_PER_IFACE_ENFORCE (or an older version) may have switched
      # IPv6 off on it before it was known as a carrier interface.
      [ "$(_sysctl_r "/proc/sys/net/ipv6/conf/$_vs_e/disable_ipv6")" = "1" ] && \
        echo 0 2>/dev/null > "/proc/sys/net/ipv6/conf/$_vs_e/disable_ipv6"
    done
    ipt_snap_stale
    if [ -n "$_vs_want" ]; then
      log_info "IPv4 only: carrier IPv6 allowed on $_vs_want"
    elif [ -n "$_vs_have_in$_vs_have_out" ]; then
      log_info "IPv4 only: no carrier service network any more, carrier IPv6 closed"
    fi
  fi
  unset _vs_force _vs_fix _vs_c _vs_t _vs_p _vs_n _vs_sig _vs_now _vs_osig _vs_ot _vs_old _vs_want \
        _vs_exp _vs_exp_s _vs_e _vs_have_in _vs_have_out
  return 0
}

v6c_teardown() {
  _v6c_lock
  while ip6tables -D INPUT  -j "$V6ND"    2>/dev/null; do :; done
  while ip6tables -D OUTPUT -j "$V6ND"    2>/dev/null; do :; done
  ip6tables -F "$V6ND" 2>/dev/null; ip6tables -X "$V6ND" 2>/dev/null
  while ip6tables -D INPUT  -j "$V6C_IN"  2>/dev/null; do :; done
  while ip6tables -D OUTPUT -j "$V6C_OUT" 2>/dev/null; do :; done
  ip6tables -F "$V6C_IN"  2>/dev/null; ip6tables -X "$V6C_IN"  2>/dev/null
  ip6tables -F "$V6C_OUT" 2>/dev/null; ip6tables -X "$V6C_OUT" 2>/dev/null
  rm -f "$V6C_FILE" 2>/dev/null
  ipt_snap_stale
  _v6c_unlock
}

# r22: list files live in lists/, resolver lists in resolvers/. A toml from
# before (an old copy edited on the sdcard, a restored backup) still names
# them bare - point those keys at the new folders. Only a bare file name is
# changed; a path the user wrote (with a /) is left alone. Returns 0 when
# the file was changed.
toml_fix_paths() {
  [ -f "$CONFIG" ] || return 1
  grep -qE "^[[:space:]]*((blocked|allowed)_(names|ips)_file|cache_file)[[:space:]]*=[[:space:]]*['\"][^/'\"]+['\"]" "$CONFIG" 2>/dev/null || return 1
  sed -i -E \
    -e "s#^([[:space:]]*(blocked|allowed)_(names|ips)_file[[:space:]]*=[[:space:]]*)(['\"])([^/'\"]+)(['\"])#\1\4lists/\5\6#" \
    -e "s#^([[:space:]]*cache_file[[:space:]]*=[[:space:]]*)(['\"])([^/'\"]+)(['\"])#\1\2resolvers/\3\4#" \
    "$CONFIG"
  mirror_to_sd dnscrypt-proxy.toml
  log_info "config: list paths pointed to lists/ and resolvers/ (r22 layout)"
  return 0
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
  toml_fix_paths && APPLY_RESTART=1
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
  ipt_snap_stale; ipt_snap
  if sn_has "$S4N" "$P_DNAT_UDP"; then
    rules_install_dns
  fi

  _prev=$(ip_mode_applied)
  echo "$_eff" > "$IP_MODE_FILE"
  [ "$_prev" != "$_eff" ] && log_info "IP mode: $_eff (was: $_prev)"
  unset _v6nat _eff _blk _prev
  return 0
}

# ── Let Android see IPv6 again after IPv4-only mode ─────────────────────────
# IPv4-only mode before r22 switched IPv6 off in the kernel, and the
# interfaces lost their IPv6 addresses (since r22 the DROP policy also
# starves them of router advertisements). Switched back on, the kernel gets them again from
# the router within seconds - but Android keeps the network's old picture
# (IPv4 only) until the network reconnects, so apps and the browser never
# try IPv6 ("IPv6 not detected"). This checks, and only if Android is
# really behind, reconnects the network the phone is using - what toggling
# Wi-Fi or mobile data by hand does.
#
# Runs detached from ctl.sh (it waits up to ~15s); results go to the log.
_default_iface() {
  ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1
}
_kernel_v6_addrs() { # <iface> -> global IPv6 addresses, one per line
  ip -o -6 addr show dev "$1" scope global 2>/dev/null | \
    sed -n 's/.* inet6 \([0-9a-fA-F:]*\)\/.*/\1/p'
}
net_refresh_for_ipv6() {
  _if=$(_default_iface)
  case "$_if" in
    wlan*) _how=wifi ;;
    rmnet* | ccmni* | seth* | v4-rmnet* | v4-ccmni*) _if=${_if#v4-}; _how=data ;;
    *)
      # A VPN (WireGuard, tun) owns the default route; the network under it
      # is the one Android has to refresh. Wi-Fi if it has an address, else
      # the mobile data interface.
      _if=""
      if ip -o -4 addr show dev wlan0 scope global 2>/dev/null | grep -q inet; then
        _if=wlan0; _how=wifi
      else
        _if=$(ip -o addr show scope global 2>/dev/null | awk '{print $2}' | grep -E '^(rmnet|ccmni|seth)' | head -n 1)
        _how=data
      fi
      if [ -z "$_if" ]; then
        log_info "IPv6 refresh: no Wi-Fi or mobile data in use - nothing to do"
        unset _if _how; return 0
      fi ;;
  esac
  # The kernel first: without an IPv6 address from the router there is
  # nothing for Android to see, and a reconnect would not change that.
  _i=0; _addrs=""
  while [ "$_i" -lt "${NET_REFRESH_WAIT:-15}" ]; do
    _addrs=$(_kernel_v6_addrs "$_if")
    [ -n "$_addrs" ] && break
    sleep 1; _i=$((_i + 1))
  done
  if [ -z "$_addrs" ]; then
    log_info "IPv6 refresh: $_if got no IPv6 address - this network seems to have no IPv6"
    unset _if _how _i _addrs; return 0
  fi
  # Does Android's view of the network already list one of them?
  _lp=$(dumpsys connectivity 2>/dev/null | grep -oE 'LinkAddresses: \[[^]]*\]')
  for _a in $_addrs; do
    case "$_lp" in
      *"$_a/"*) log_info "IPv6 refresh: Android already sees IPv6 on $_if"
                unset _if _how _i _addrs _lp _a; return 0 ;;
    esac
  done
  log_info "IPv6 refresh: Android does not see the IPv6 address of $_if yet - reconnecting $_how"
  svc "$_how" disable 2>/dev/null
  sleep 2
  svc "$_how" enable 2>/dev/null
  unset _if _how _i _addrs _lp _a
  return 0
}

# ── What kind of network is this? (for the WebUI and a boot hint) ────────────
# A clat interface (v4-<iface>) is Android's 464XLAT: the network is IPv6
# only and IPv4 is translated. Its 192.0.0.x address is not real IPv4.
# The network Android uses for internet: the table of its default-network
# rule ("31000: from all fwmark 0x0/0xffff iif lo lookup <iface>"). Hotspot,
# VPN and IMS interfaces also have addresses and must not count (r17).
net_default_iface() {
  ip rule 2>/dev/null | awk '/fwmark 0(x0)?\/0xffff iif lo lookup/ { print $NF; exit }'
}
net_has_ipv4() {
  _ni=$(net_default_iface)
  if [ -n "$_ni" ]; then ip -o -4 addr show dev "$_ni" scope global 2>/dev/null | grep -q 'inet '
  else ip -o -4 addr show scope global 2>/dev/null | grep -v ' v4-' | grep -q 'inet '; fi
  _r=$?; unset _ni; return $_r
}
net_has_ipv6() {
  _ni=$(net_default_iface)
  if [ -n "$_ni" ]; then ip -o -6 addr show dev "$_ni" scope global 2>/dev/null | grep -q 'inet6 '
  else ip -o -6 addr show scope global 2>/dev/null | grep -q 'inet6 '; fi
  _r=$?; unset _ni; return $_r
}
# A VPN is connected (Android's VPN uid rule) / it carries IPv6. A VPN with
# no IPv6 route (e.g. a WireGuard config with only an IPv4 address) lets
# apps' IPv6 go around it on a network that has IPv6.
vpn_table() { ip rule 2>/dev/null | awk '/uidrange 0-99999 lookup/ { print $NF; exit }'; }
vpn_has_ipv6() {
  _vt=$(vpn_table); [ -n "$_vt" ] || return 1
  ip -6 route show table "$_vt" 2>/dev/null | grep -qE '^(default|::/0) '
  _r=$?; unset _vt; return $_r
}
# WG Shield Arm64 (kernel WireGuard module of the same set): Android sees no
# VPN there, so its tunnel is read from the status file it publishes
# (key=value: state, tunnel, ipv6 = tunnel | blocked | off, ...).
WGS_MODDIR="${DNSC_WGS_MODDIR:-/data/adb/modules/wg-shield}"
# WG Shield 1.0-r4+ keeps its status in /data/adb/wg-shield/state/, older
# versions in /data/adb/wg-shield-state/ - chosen on every read.
WGS_STATUS="${DNSC_WGS_STATUS:-/data/adb/wg-shield/state/status}"
WGS_STATUS_OLD="${DNSC_WGS_STATUS_OLD:-/data/adb/wg-shield-state/status}"
wgs_installed() { # -> absent | disabled | enabled
  if [ ! -f "$WGS_MODDIR/module.prop" ]; then echo absent
  elif [ -f "$WGS_MODDIR/disable" ] || [ -f "$WGS_MODDIR/remove" ]; then echo disabled
  else echo enabled; fi
}
wgs_get() {
  if [ -f "$WGS_STATUS" ]; then _wf=$WGS_STATUS; else _wf=$WGS_STATUS_OLD; fi
  sed -n "s/^$1=//p" "$_wf" 2>/dev/null | head -n 1
  unset _wf
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
