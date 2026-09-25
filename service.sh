#!/system/bin/sh
# service.sh - dnscrypt-proxy watchdog (SukiSU / KernelSU / Magisk)
# arm64-only module
#
# Owns the daemon: starts it, checks it, restarts it, keeps the iptables
# rules in place, and publishes what it sees to $HEALTH_FILE for ctl.sh
# and the WebUI. Anything that wants the daemon restarted stops it and
# lets this loop bring it back, so there is only ever one owner.

MODDIR=${0%/*}

if [ ! -f "$MODDIR/sh/common.sh" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] sh/common.sh missing - the module is incomplete, reflash it" >> /data/adb/dnscrypt-proxy.log
  exit 1
fi
# shellcheck source=/dev/null
. "$MODDIR/sh/common.sh"
# shellcheck source=/dev/null
[ -f "$MODDIR/sh/blocklist.sh" ] && . "$MODDIR/sh/blocklist.sh"
load_settings

mkdir -p "$STATE_DIR" "$DATA_DIR"

[ "$RULES_OK" -eq 1 ] || log_error "sh/rules.sh missing - running WITHOUT iptables management, DNS is not being redirected"

# -----------------------------------------------
# Timing. One tick is 10 seconds.
#
#   liveness probe     every 3 ticks (30s). 3 silent in a row = hung.
#   resolution probe   every 6 ticks (60s), and on every daemon start.
#
# Both probes are real DNS queries and show up in the dashboard's query
# list and totals: roughly 4,300 a day. The dashboard filters them out of
# the lists; the counters in dnscrypt-proxy itself include them.
# -----------------------------------------------
TICK=10
LIVE_EVERY=3
RESOLVE_EVERY=6
LIVE_FAIL_MAX=3
RESTART_BUDGET=5
RESTART_WINDOW=900

SCRIPT_START=$(mono_now)
BOOT_FAILSAFE_SECONDS=90

deadline_passed() {
  [ $(( $(mono_now) - SCRIPT_START )) -ge "$BOOT_FAILSAFE_SECONDS" ]
}

renice -n 10 -p $$ 2>/dev/null

# -----------------------------------------------
# Single instance. Kill any watchdog left over from a previous flash, then
# any daemon it left behind - r10 killed the old watchdog but not its
# daemon, so after an update the OLD binary kept :5354 until reboot.
# -----------------------------------------------
MYPID=$$
for _p in /proc/[0-9]*; do
  _pid=${_p#/proc/}
  [ "$_pid" = "$MYPID" ] && continue
  case "$(tr '\0' ' ' 2>/dev/null < "$_p/cmdline")" in
    *dnscrypt-proxy-android/service.sh*) kill "$_pid" 2>/dev/null ;;
  esac
done
unset _p _pid
echo "$MYPID" > "$WATCHDOG_PIDFILE"
# USR1 = "the daemon was just stopped, look now" (see wake_watchdog). The
# trap only has to exist: it interrupts the wait at the end of the loop.
trap ':' USR1
echo "$MYPID" > "$WATCHDOG_WAKE"

if daemon_any; then
  log_info "stopping dnscrypt-proxy left over from a previous instance"
  stop_daemon
fi

log_info "watchdog started (pid $MYPID, busybox: ${BB:-none}, SELinux: $(getenforce 2>/dev/null || echo unknown))"

# -----------------------------------------------
# State published to $HEALTH_FILE
# -----------------------------------------------
H_STATE="starting"
LIVENESS="unknown"
RESOLVING="unknown"
DAEMON_STARTED=0
RESOLVED_AT=0
HEALTH_RESTARTS=0
LAST_RESTART_REASON="none"
FAILSAFE_TRIGGERED=0
NOW=$SCRIPT_START

write_health() {
  {
    echo "state=$H_STATE"
    echo "liveness=$LIVENESS"
    echo "resolving=$RESOLVING"
    echo "probe_tool=$(probe_label)"
    echo "daemon_started=$DAEMON_STARTED"
    echo "resolved_at=$RESOLVED_AT"
    echo "health_restarts=$HEALTH_RESTARTS"
    echo "last_restart_reason=$LAST_RESTART_REASON"
    echo "failsafe=$FAILSAFE_TRIGGERED"
    echo "health_restart_enabled=$HEALTH_AUTORESTART"
    echo "clock=monotonic"
    echo "tick_at=$NOW"
  } > "$HEALTH_FILE.tmp" 2>/dev/null && mv -f "$HEALTH_FILE.tmp" "$HEALTH_FILE"
}

# -----------------------------------------------
# Health auto-restart is only safe when the liveness probe is answered
# locally, i.e. with block_undelegated = true. Otherwise "no reply" could
# just mean "no internet", and restarting would achieve nothing.
# -----------------------------------------------
HEALTH_AUTORESTART=0
check_health_prereqs() {
  if [ "$HEALTH_RESTART" != "1" ]; then
    HEALTH_AUTORESTART=0
  elif undelegated_enabled; then
    HEALTH_AUTORESTART=1
  else
    HEALTH_AUTORESTART=0
    log_warn "block_undelegated is not true in the toml - automatic restart of a hung daemon is disabled"
  fi
}
check_health_prereqs

# -----------------------------------------------
# Failsafe: with the daemon dead, the redirect NATs every DNS query to a
# port nobody is listening on - "no internet", and it does not heal on
# reboot because post-fs-data.sh reinstalls the same rules. After the grace
# period, take the redirect down so the phone is usable, and put it back
# the moment the daemon is listening again.
#
# r11 also fired this when the daemon WAS listening but upstream did not
# resolve. The rule-maintenance block put the redirect straight back on
# the next tick anyway, so all it did was open a 10-second plaintext
# window. It is now only for a dead daemon; a running daemon with no
# upstream stays fail-closed and is reported as "degraded".
# -----------------------------------------------
failsafe_open_dns() {
  [ "$FAILSAFE_TRIGGERED" -eq 1 ] && return
  log_error "FAILSAFE - dnscrypt-proxy is not running. Removing the port-53 redirect so DNS is not black-holed. Queries go out in PLAINTEXT until the daemon recovers."
  rules_remove_dns
  FAILSAFE_TRIGGERED=1
  : > "$STATE_DIR/failsafe_fired"
}

failsafe_clear() {
  [ "$FAILSAFE_TRIGGERED" -eq 1 ] && log_info "failsafe cleared - DNS is protected again"
  FAILSAFE_TRIGGERED=0
  rm -f "$STATE_DIR/failsafe_fired"
}

# -----------------------------------------------
# Restart budget: at most $RESTART_BUDGET health restarts per
# $RESTART_WINDOW seconds. A daemon that hangs again right after every
# restart has a problem a restart does not fix, and cycling it forever
# only adds churn and log noise.
# -----------------------------------------------
BUDGET_START=0
BUDGET_USED=0
BUDGET_WARNED=0
restart_budget_ok() {
  if [ $((NOW - BUDGET_START)) -ge "$RESTART_WINDOW" ]; then
    BUDGET_START=$NOW
    BUDGET_USED=0
    BUDGET_WARNED=0
  fi
  [ "$BUDGET_USED" -lt "$RESTART_BUDGET" ] || return 1
  BUDGET_USED=$((BUDGET_USED + 1))
  return 0
}

# -----------------------------------------------
# Start the daemon and wait for it. Returns 0 once it is listening.
# -----------------------------------------------
start_daemon() {
  rotate_log

  # customize.sh installs the config; this is only a safety net for the
  # case where someone deleted it by hand.
  if [ ! -f "$CONFIG" ] && [ -f "$MODDIR/config/dnscrypt-proxy.toml" ]; then
    log_warn "config missing from $DATA_DIR, restoring module default"
    cp -f "$MODDIR/config/dnscrypt-proxy.toml" "$CONFIG" 2>/dev/null
  fi
  if [ ! -f "$CONFIG" ]; then
    log_error "$CONFIG does not exist, cannot start"
    return 1
  fi

  log_info "starting dnscrypt-proxy"
  echo 0 > "$PROBE_COUNT_FILE" 2>/dev/null
  # exec, so $! is the daemon itself and not a wrapper subshell. cd first:
  # the relative filenames inside the toml resolve against the cwd.
  ( cd "$DATA_DIR" && exec "$DNSCRYPT_BIN" -config "$CONFIG" >> "$LOG" 2>&1 ) &
  _pid=$!
  echo "$_pid" > "$DAEMON_PIDFILE"
  DAEMON_STARTED=$(mono_now)
  LIVENESS="unknown"
  RESOLVING="unknown"

  _i=0
  while [ "$_i" -lt 60 ]; do
    is_listening && break
    if [ ! -d "/proc/$_pid" ]; then
      log_error "dnscrypt-proxy exited during startup - its own error is in the lines above"
      rm -f "$DAEMON_PIDFILE"
      unset _pid _i
      return 1
    fi
    sleep 1
    _i=$((_i + 1))
  done
  if ! is_listening; then
    log_warn "dnscrypt-proxy did not bind :$LISTEN_PORT within 60s"
    unset _pid _i
    return 1
  fi

  # While protection is paused the daemon runs, but the redirect stays off.
  if ! is_paused; then
    rules_install_dns
    [ "$QUIC_BLOCK" = "1" ] && rules_install_quic
  fi
  failsafe_clear
  # Publish right away: the resolution wait below can take half a minute,
  # and the WebUI should not show "failsafe" for a daemon that is back.
  # "starting", not the computed state: a fresh daemon has no certificates
  # yet, and its first queries fail for a few seconds on every restart -
  # that is not "nothing resolves".
  H_STATE="starting"
  update_module_status
  write_health

  # Up to ~60s without upstream. Keep the health file fresh meanwhile, or
  # the WebUI reports the watchdog as stalled while it is only waiting.
  # Short probes, close together: the daemon usually has its servers within
  # two or three seconds, and r13's first build (3s probes, 3s apart - a
  # busybox nc waits out its whole -w even after the reply) kept the WebUI
  # on "Starting" for ~10s after that. Same ~60s budget as before.
  _i=0
  while [ "$_i" -lt 20 ]; do
    probe_resolution 1
    [ "$RESOLVING" = "ok" ] && break
    NOW=$(mono_now)
    write_health
    sleep 1
    _i=$((_i + 1))
  done
  if [ "$RESOLVING" = "ok" ]; then
    RESOLVED_AT=$(mono_now)
    log_info "dnscrypt-proxy ready on :$LISTEN_PORT and resolving (pid $_pid, probe: $(probe_label))"
  elif [ "$RESOLVING" = "unknown" ]; then
    log_warn "dnscrypt-proxy listening (pid $_pid), but this device has no tool to verify resolution"
  else
    log_warn "dnscrypt-proxy listening (pid $_pid), but not resolving yet ($RESOLVING) - upstream or network not ready"
  fi
  unset _pid _i
  return 0
}

# -----------------------------------------------
# IPv6 killswitch upkeep (IP mode "ipv4" only)
# -----------------------------------------------
sysctl_set() {
  [ -r "$1" ] || return 0
  [ "$(cat "$1" 2>/dev/null)" = "$2" ] && return 0
  echo "$2" 2>/dev/null > "$1"
}

IPV6_PROPS_SET=0
IPV6_LAST_REDISABLED=""
IPV6_LAST_REDISABLED_AT=0

# Idempotent: compares before writing, sets props once per boot and checks
# the loopback rules with -C. r11.0 rewrote everything every 60s and made
# dnscrypt-proxy rotate its client keys once a minute for nothing.
enforce_ipv6_disable() {
  # The applied mode, not the loaded setting: a switch made from the WebUI
  # takes effect at once, and this must not fight it for the up to a minute
  # it takes the watchdog to notice the settings file changed.
  [ "$(ip_mode_applied)" = "ipv4" ] || return

  sysctl_set /proc/sys/net/ipv6/conf/all/disable_ipv6     1
  sysctl_set /proc/sys/net/ipv6/conf/default/disable_ipv6 1
  sysctl_set /proc/sys/net/ipv6/conf/all/accept_ra        0
  sysctl_set /proc/sys/net/ipv6/conf/default/accept_ra    0

  # Per-interface enforcement is off by default: the modem's rmnet PDN
  # contexts re-enable IPv6 on a timer, fighting them is endless churn, and
  # the ip6tables DROP policy below is what actually stops IPv6 anyway.
  if [ "$IPV6_PER_IFACE_ENFORCE" = "1" ]; then
    _redisabled=""
    for _c in /proc/sys/net/ipv6/conf/*; do
      _ifname=${_c##*/}
      [ "$_ifname" = "lo" ] && continue
      if [ -r "$_c/disable_ipv6" ] && [ "$(cat "$_c/disable_ipv6" 2>/dev/null)" != "1" ]; then
        echo 1 2>/dev/null > "$_c/disable_ipv6" && _redisabled="$_redisabled $_ifname"
      fi
      sysctl_set "$_c/accept_ra" 0
    done
    if [ -n "$_redisabled" ]; then
      if [ "$_redisabled" != "$IPV6_LAST_REDISABLED" ] || \
         [ $((NOW - IPV6_LAST_REDISABLED_AT)) -ge 600 ]; then
        log_info "re-disabled IPv6 on:$_redisabled (something keeps turning it back on)"
        IPV6_LAST_REDISABLED="$_redisabled"
        IPV6_LAST_REDISABLED_AT=$NOW
      fi
    fi
    unset _c _ifname _redisabled
  fi

  if [ "$IPV6_PROPS_SET" -eq 0 ]; then
    resetprop net.ipv6.conf.all.disable_ipv6 1     2>/dev/null
    resetprop net.ipv6.conf.default.disable_ipv6 1 2>/dev/null
    IPV6_PROPS_SET=1
  fi

  # The actual killswitch.
  ipt_snap
  if [ "$S6OK" = 1 ] && ! printf '%s\n' "$S6F" | grep -q '^-P OUTPUT DROP'; then
    log_warn "ip6tables OUTPUT policy was not DROP, restoring the IPv6 killswitch"
    ip6tables -P INPUT   DROP 2>/dev/null
    ip6tables -P OUTPUT  DROP 2>/dev/null
    ip6tables -P FORWARD DROP 2>/dev/null
    ipt_snap_stale
  fi
  sn_has "$S6F" '^-A INPUT -i lo -j ACCEPT$' || { ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null; ipt_snap_stale; }
  sn_has "$S6F" '^-A OUTPUT -o lo -j ACCEPT$' || { ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null; ipt_snap_stale; }
}

# -----------------------------------------------
# sdcard mirror.
#
# seed_sdcard did not exist up to r11.6 - it was called but never defined,
# and mtime_of was missing too, so every sync comparison failed and edits
# made on the sdcard were never copied in. Both are real now.
#
# Seeding copies back anything missing from the mirror, then gives the
# /data copy the SAME mtime (touch -r). Without that, the fresh sdcard copy
# is newer, the next sync takes it for a user edit, and an untouched toml
# restarts the daemon.
# -----------------------------------------------
seed_sdcard() {
  [ -d "$SD_DIR" ] || mkdir -p "$SD_DIR" 2>/dev/null || return 1
  for _f in $SYNC_FILES; do
    [ -f "$DATA_DIR/$_f" ] || continue
    [ -f "$SD_DIR/$_f" ] && continue
    if cp -f "$DATA_DIR/$_f" "$SD_DIR/$_f" 2>/dev/null; then
      touch -r "$SD_DIR/$_f" "$DATA_DIR/$_f" 2>/dev/null
      log_info "restored $_f to the sdcard mirror"
    fi
  done
  unset _f
  return 0
}

sync_from_sdcard() {
  [ -d "$SD_DIR" ] || return 1
  _toml_changed=0
  _lists_changed=0
  _custom_changed=0
  for _f in $SYNC_FILES; do
    [ -f "$SD_DIR/$_f" ] || continue
    if [ ! -f "$DATA_DIR/$_f" ] || \
       [ "$(mtime_of "$SD_DIR/$_f")" -gt "$(mtime_of "$DATA_DIR/$_f")" ]; then
      cp -f "$SD_DIR/$_f" "$DATA_DIR/$_f" 2>/dev/null || continue
      log_info "synced $_f from the sdcard"
      case "$_f" in
        dnscrypt-proxy.toml)      _toml_changed=1 ;;
        custom-blocked-names.txt) _custom_changed=1 ;;
        *)                        _lists_changed=1 ;;
      esac
    fi
  done
  unset _f

  # A custom-list edit rebuilds blocked-names.txt from the cached sources:
  # offline, a few seconds, and removed lines really disappear.
  if [ "$_custom_changed" -eq 1 ] || [ -f "$BL_REBUILD_PENDING" ]; then
    if command -v bl_rebuild_custom >/dev/null 2>&1; then
      bl_rebuild_custom
      case $? in
        0) _lists_changed=1 ;;
        2) log_info "custom list changed while a blocklist job is running - applying it right after" ;;
      esac
    fi
  fi

  if [ "$_toml_changed" -eq 1 ]; then
    log_info "config changed, restarting dnscrypt-proxy"
    # listen_addresses and block_ipv6 belong to the IP mode. A toml edited
    # on the sdcard (or copied from another phone) can carry the other
    # mode's values - ::1 in ipv4 mode, where loopback has no IPv6 and the
    # daemon cannot bind, so it never started and the failsafe opened DNS.
    apply_ip_mode
    stop_daemon
    check_health_prereqs
  elif [ "$_lists_changed" -eq 1 ]; then
    log_info "lists changed, reloading dnscrypt-proxy"
    reload_daemon
    case $? in
      0) log_info "reload confirmed by dnscrypt-proxy" ;;
      1) log_warn "dnscrypt-proxy did not acknowledge the reload - restarting it so the new lists take effect"
         stop_daemon ;;
    esac
  fi
  unset _toml_changed _lists_changed _custom_changed
}

# -----------------------------------------------
# Status line in the manager
# -----------------------------------------------
LAST_STATUS=""
update_module_status() {
  case "$H_STATE" in
    working)  _s="Working 🌬🌬🌬" ;;
    running)  _s="Running 🌬 (resolution not verifiable)" ;;
    degraded) _s="Degraded ⚠️ protected, but upstream not reachable" ;;
    hung)     _s="Not responding ⚠️ restarting" ;;
    failsafe) _s="Failsafe 📵 DNS unprotected" ;;
    paused)   _s="Paused ⏸ DNS unencrypted for now" ;;
    starting) _s="Starting ⏳" ;;
    *)        _s="Not Working 📵❌📵" ;;
  esac
  if [ "$_s" != "$LAST_STATUS" ]; then
    set_module_status "$_s"
    LAST_STATUS="$_s"
  fi
  unset _s
}

# -----------------------------------------------
# Automatic blocklist update (BLOCKLIST_AUTO = daily | weekly | off).
# Checked every ~10 minutes. Wall-clock time is right here: the interval
# is days and has to survive reboots. It is only trusted once the clock
# has been set (anything before 2023 means it has not), and only while
# DNS is actually resolving. A failed attempt waits an hour before the
# next one instead of retrying every ten minutes.
# -----------------------------------------------
auto_update_check() {
  case "$BLOCKLIST_AUTO" in
    daily)  _iv=86400 ;;
    weekly) _iv=604800 ;;
    *) return 0 ;;
  esac
  [ "$H_STATE" = "working" ] || { unset _iv; return 0; }
  _now=$(date +%s)
  [ "$_now" -gt 1672531200 ] || { unset _iv _now; return 0; }
  _last=$(cat "$BL_LAST_EPOCH" 2>/dev/null); _last=$((_last + 0))
  _att=$(cat "$BL_LAST_ATTEMPT" 2>/dev/null); _att=$((_att + 0))
  if [ $((_now - _last)) -ge "$_iv" ] && [ $((_now - _att)) -ge 3600 ] && ! update_running; then
    log_info "automatic blocklist update ($BLOCKLIST_AUTO) starting"
    start_update_worker --auto
  fi
  unset _iv _now _last _att
}

compute_state() {
  if ! is_listening; then
    if [ "$FAILSAFE_TRIGGERED" -eq 1 ]; then H_STATE="failsafe"; else H_STATE="down"; fi
  elif is_paused; then
    H_STATE="paused"
  elif [ "$LIVENESS" = "silent" ]; then
    H_STATE="hung"
  else
    case "$RESOLVING" in
      ok)               H_STATE="working" ;;
      noanswer|silent)  H_STATE="degraded" ;;
      *)                H_STATE="running" ;;
    esac
  fi
}

# -----------------------------------------------
# Leftovers from r11 and earlier: the busybox httpd on :5556 and the
# metrics.json it served are gone - the WebUI talks to ctl.sh through the
# root manager now, and reads the metrics itself only while it is open.
# -----------------------------------------------
if [ -f "$HTTPD_PIDFILE" ]; then
  _old=$(cat "$HTTPD_PIDFILE" 2>/dev/null)
  if [ -n "$_old" ] && tr '\0' ' ' 2>/dev/null < "/proc/$_old/cmdline" | grep -q 'httpd.*5556'; then
    kill "$_old" 2>/dev/null
  fi
  rm -f "$HTTPD_PIDFILE"
  unset _old
fi
rm -f "$WEBROOT/metrics.json" "$WEBROOT/metrics.json.tmp" 2>/dev/null

# post-fs-data applied the IP mode at boot; this covers a watchdog started
# by hand, or a settings change made between the two.
if [ "$(ip_mode_applied)" = "none" ] || [ "$(ip_mode_applied | sed 's/-limited$//')" != "$IP_MODE" ]; then
  apply_ip_mode
fi

TICK_NO=0
CONF_MTIME=$(mtime_of "$CONF")
LIVE_FAILS=0
START_FAILS=0
SD_SEEDED=0
IPV6_HINTED=0

# -----------------------------------------------
# Main loop
# -----------------------------------------------
while true; do
  NOW=$(mono_now)
  TICK_NO=$((TICK_NO + 1))
  ipt_snap_stale               # fresh lock-free snapshot for this tick

  # ── Daemon up? ──
  # After three failed starts in a row (a broken toml, a missing binary)
  # retry once a minute instead of every tick: the daemon's own error is
  # already in the log, repeating it every 10 seconds only buries it.
  if ! is_listening; then
    if [ "$START_FAILS" -lt 3 ] || [ $((TICK_NO % 6)) -eq 0 ]; then
      if start_daemon; then
        START_FAILS=0
      else
        START_FAILS=$((START_FAILS + 1))
        [ "$START_FAILS" -eq 3 ] && log_error "dnscrypt-proxy failed to start 3 times in a row - retrying once a minute from now on"
        deadline_passed && failsafe_open_dns
      fi
      NOW=$(mono_now)
    fi
  fi

  if is_listening; then
    # ── Liveness ──
    if [ $((TICK_NO % LIVE_EVERY)) -eq 0 ]; then
      probe_liveness
      if [ "$LIVENESS" = "silent" ]; then
        LIVE_FAILS=$((LIVE_FAILS + 1))
        log_warn "dnscrypt-proxy did not answer a local query ($LIVE_FAILS/$LIVE_FAIL_MAX)"
      else
        LIVE_FAILS=0
      fi
    fi

    if [ "$LIVE_FAILS" -ge "$LIVE_FAIL_MAX" ] && [ "$HEALTH_AUTORESTART" -eq 1 ]; then
      if restart_budget_ok; then
        log_warn "dnscrypt-proxy is holding :$LISTEN_PORT but not answering - restarting it"
        HEALTH_RESTARTS=$((HEALTH_RESTARTS + 1))
        LAST_RESTART_REASON="hung"
        LIVE_FAILS=0
        H_STATE="hung"
        update_module_status
        write_health
        stop_daemon
        continue
      elif [ "$BUDGET_WARNED" -eq 0 ]; then
        log_error "dnscrypt-proxy keeps hanging: $RESTART_BUDGET restarts in $((RESTART_WINDOW / 60)) minutes. Not restarting again until the window passes - check the lines above for the cause."
        BUDGET_WARNED=1
      fi
    fi

    # ── Resolution ──
    if [ $((TICK_NO % RESOLVE_EVERY)) -eq 0 ]; then
      probe_resolution
      [ "$RESOLVING" = "ok" ] && RESOLVED_AT=$NOW
    fi

    # ── Rule maintenance, every tick ──
    # netd rebuilds these chains on connectivity changes, VPN start and
    # tethering toggles. Reinstall on the strength of the port being open
    # alone - never gate this on a probe that itself needs the rules.
    if [ -f "$PAUSE_FILE" ]; then
      if is_paused; then
        # Paused from the WebUI: keep the redirect off, and make sure it
        # is off even if something else reinstalled it meanwhile.
        rules_dns_any_present && rules_remove_dns
      else
        rm -f "$PAUSE_FILE"
        log_info "pause ended - protection resumed"
        rules_install_dns
      fi
    elif ! rules_dns_present; then
      log_info "DNS redirect missing (netd flush or failsafe), reinstalling"
      rules_install_dns
      failsafe_clear
    fi
    [ "$QUIC_BLOCK" = "1" ] && rules_install_quic
  fi
  # ── Hotspot clients, every tick, daemon up or not ──
  # Clients go through the phone's own DNS forwarder, which goes through
  # the same redirect as the phone: while the daemon is down they are
  # exactly as (un)protected as the phone. Pause and the switches are
  # handled inside.
  hotspot_sync

  # No failsafe here. The daemon can be down at this point for a good
  # reason - ctl.sh just stopped it for a restart or an IP mode switch - and
  # opening DNS then meant a few seconds of plaintext on every restart. The
  # failsafe fires where it belongs: when an actual start attempt fails
  # (top of the loop). The daemon is started again on the next pass.

  compute_state
  update_module_status
  write_health

  # ── Settings changed from the WebUI? Checked every tick: a stale
  # QUIC_BLOCK here would put back a rule the user just switched off. ──
  _cm=$(mtime_of "$CONF")
  if [ "$_cm" != "$CONF_MTIME" ]; then
    [ -n "$CONF_MTIME" ] && log_info "settings file changed - reloaded"
    CONF_MTIME=$_cm
    load_settings
    check_health_prereqs
    [ "$QUIC_BLOCK" = "1" ] || rules_remove_quic
    command -v bl_catalog_reset >/dev/null 2>&1 && bl_catalog_reset
    _applied=$(ip_mode_applied)
    if [ "${_applied%-limited}" != "$IP_MODE" ]; then
      apply_ip_mode
      if [ "$APPLY_RESTART" = "1" ] && is_listening; then
        log_info "restarting dnscrypt-proxy for the new IP mode"
        stop_daemon
      fi
    fi
    unset _applied
  fi
  unset _cm

  # ── sdcard sync, every ~60s ──
  if [ $((TICK_NO % 6)) -eq 0 ] && [ -d "/storage/emulated/0" ]; then
    if [ "$SD_SEEDED" -eq 0 ]; then
      seed_sdcard && SD_SEEDED=1
    fi
    sync_from_sdcard
  fi

  # ── IPv4 mode on a network without IPv4? Say so, once per boot. ──
  if [ "$IPV6_HINTED" -eq 0 ] && [ $((TICK_NO % 30)) -eq 0 ] && deadline_passed && \
     [ "$(ip_mode_applied)" = "ipv4" ] && [ "$H_STATE" = "degraded" ] && \
     has_live_interface && ! net_has_ipv4; then
    log_warn "no IPv4 address on this network and nothing resolves. If your carrier is IPv6-only, switch the IP mode to 'IPv6 compatible' in the WebUI (System tab)."
    IPV6_HINTED=1
  fi

  [ $((TICK_NO % 6)) -eq 0 ] && enforce_ipv6_disable

  # ── Log rotation and auto-update check, every ~10 minutes ──
  if [ $((TICK_NO % 60)) -eq 0 ]; then
    rotate_log
    auto_update_check
  fi

  # Interruptible: wake_watchdog (USR1) ends the wait early.
  sleep "$TICK" &
  _slp=$!
  wait "$_slp" 2>/dev/null
  kill "$_slp" 2>/dev/null
  unset _slp
done
