#!/system/bin/sh
# ctl.sh - command-line control for dnscrypt-proxy-android.
#
# Everything the WebUI does goes through here, and every command can be
# run by hand from a root shell:
#
#   su -c sh /data/adb/modules/dnscrypt-proxy-android/ctl.sh status
#
# Output is key=value, one per line, so it parses the same in the WebUI,
# in a script and by eye. Exit code 0 = ok, 1 = failed, 2 = usage error.

MODDIR=${0%/*}
case "$MODDIR" in
  /*) : ;;
  *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;;
esac

if [ ! -f "$MODDIR/sh/common.sh" ]; then
  echo "ok=0"
  echo "error=sh/common.sh missing - reflash the module"
  exit 1
fi
# shellcheck source=/dev/null
. "$MODDIR/sh/common.sh"
# shellcheck source=/dev/null
[ -f "$MODDIR/sh/blocklist.sh" ] && . "$MODDIR/sh/blocklist.sh"
# shellcheck source=/dev/null
[ -f "$MODDIR/sh/tools.sh" ] && . "$MODDIR/sh/tools.sh"
# shellcheck source=/dev/null
[ -f "$MODDIR/sh/resolvers.sh" ] && . "$MODDIR/sh/resolvers.sh"
load_settings

if [ "$(id -u 2>/dev/null)" != "0" ]; then
  echo "ok=0"
  echo "error=must run as root"
  exit 1
fi

yn() { if "$@" >/dev/null 2>&1; then echo 1; else echo 0; fi; }

health_get() { # <key>
  sed -n "s/^$1=//p" "$HEALTH_FILE" 2>/dev/null | head -n 1
}

# ── status ───────────────────────────────────────────────────────────────────
cmd_status() {
  _now=$(mono_now)

  echo "version=$(sed -n 's/^version=//p' "$MODPROP" 2>/dev/null)"
  echo "version_code=$(sed -n 's/^versionCode=//p' "$MODPROP" 2>/dev/null)"
  echo "binary_version=$("$DNSCRYPT_BIN" -version 2>/dev/null | head -n 1)"

  # Processes
  _wd=$(watchdog_pid)
  echo "watchdog=$([ -n "$_wd" ] && echo running || echo stopped)"
  echo "watchdog_pid=${_wd:-}"
  _dp=$(daemon_pid)
  echo "daemon=$([ -n "$_dp" ] && echo running || echo stopped)"
  echo "daemon_pid=${_dp:-}"
  _started=$(health_get daemon_started)
  if [ -n "$_dp" ] && [ "${_started:-0}" -gt 0 ]; then
    echo "daemon_uptime=$((_now - _started))"
  else
    echo "daemon_uptime=0"
  fi
  echo "listening=$(yn is_listening)"

  # What the watchdog last saw
  _tick=$(health_get tick_at)
  echo "state=$(health_get state)"
  echo "liveness=$(health_get liveness)"
  echo "resolving=$(health_get resolving)"
  echo "probe_tool=$(health_get probe_tool)"
  _res=$(health_get resolved_at)
  if [ "${_res:-0}" -gt 0 ]; then echo "resolved_ago=$((_now - _res))"; else echo "resolved_ago="; fi
  echo "health_restarts=$(health_get health_restarts)"
  echo "last_restart_reason=$(health_get last_restart_reason)"
  echo "health_restart_enabled=$(health_get health_restart_enabled)"
  echo "failsafe=$(health_get failsafe)"
  echo "paused_left=$(pause_left)"
  if [ "${_tick:-0}" -gt 0 ]; then echo "tick_age=$((_now - _tick))"; else echo "tick_age="; fi

  # Rules, checked live
  echo "rule_nat_v4=$(yn iptables -t nat -C OUTPUT -p udp --dport 53 -j DNAT --to-destination "$DNS_REDIR")"
  echo "rule_guard_v4=$(yn iptables -C OUTPUT ! -o lo -p udp --dport 53 -j DROP)"
  echo "rule_guard_v6=$(yn ip6tables -C OUTPUT ! -o lo -p udp --dport 53 -j DROP)"
  echo "rule_quic_v4=$(yn iptables -C OUTPUT -p udp --dport 443 -j DROP)"
  echo "rule_quic_v6=$(yn ip6tables -C OUTPUT -p udp --dport 443 -j DROP)"
  echo "ipv6_policy=$(ip6tables -S OUTPUT 2>/dev/null | sed -n 's/^-P OUTPUT //p' | head -n 1)"
  echo "rule_nat_v6=$(yn ip6tables -t nat -C OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 5354)"

  # IP mode and the network it is running on
  echo "ip_mode=$IP_MODE"
  echo "ip_mode_effective=$(ip_mode_applied)"
  echo "ip6_nat=$(yn have_ip6_nat)"
  echo "net_ipv4=$(yn net_has_ipv4)"
  echo "net_ipv6=$(yn net_has_ipv6)"
  echo "net_clat=$(yn net_has_clat)"
  echo "owner_match=$([ -f "$OWNER_FLAG_FILE" ] && echo 0 || echo 1)"
  echo "rules_file=$RULES_OK"

  # System
  echo "selinux=$(getenforce 2>/dev/null)"
  echo "private_dns=$(settings get global private_dns_mode 2>/dev/null)"
  echo "busybox=${BB:-none}"
  echo "live_interface=$(yn has_live_interface)"

  # Blocklist
  if [ -f "$BLOCKLIST" ]; then
    _n=$(wc -l 2>/dev/null < "$BLOCKLIST"); echo "blocklist_lines=$((_n + 0))"
  else
    echo "blocklist_lines=0"
  fi
  echo "blocklist_domains=$(blocklist_domains)"
  echo "blocklist_updated=$(cat "$LAST_UPDATE_FILE" 2>/dev/null)"

  # Settings
  for _k in $SETTINGS_KEYS; do
    eval "echo \"setting_$_k=\$$_k\""
  done

  echo "ok=1"
  unset _now _wd _dp _started _tick _res _n _k
}

# ── probe: run both checks now, instead of reading the last result ─────────
cmd_probe() {
  if ! is_listening; then
    echo "listening=0"
    echo "ok=0"
    return 1
  fi
  echo "listening=1"
  probe_liveness
  echo "liveness=$LIVENESS"
  echo "liveness_bytes=$Q_LEN"
  probe_resolution
  echo "resolving=$RESOLVING"
  echo "resolving_bytes=$Q_LEN"
  echo "probe_tool=$(probe_label)"
  echo "ok=1"
}

# ── restart: stop the daemon, let the watchdog bring it back ────────────────
# Refuses when the watchdog is not running: stopping the daemon then would
# leave the redirect pointing at nothing, which is "no internet".
cmd_restart() {
  if [ -z "$(watchdog_pid)" ]; then
    echo "ok=0"
    echo "error=watchdog is not running - nothing would start the daemon again"
    return 1
  fi
  log_info "restart requested via ctl.sh"
  stop_daemon
  _i=0
  while [ "$_i" -lt 45 ]; do
    if is_listening; then
      echo "ok=1"
      echo "daemon_pid=$(daemon_pid)"
      echo "took=$_i"
      unset _i
      return 0
    fi
    sleep 1
    _i=$((_i + 1))
  done
  unset _i
  echo "ok=0"
  echo "error=daemon did not come back within 45s - see the log"
  return 1
}

# ── reload: re-read lists without dropping the listener ─────────────────────
# Confirmed, not assumed: if the daemon does not acknowledge the SIGHUP it
# is restarted, which reads every list from scratch.
cmd_reload() {
  reload_daemon
  case $? in
    0)
      log_info "reload requested via ctl.sh - confirmed by dnscrypt-proxy"
      echo "ok=1"
      echo "method=reload"
      ;;
    1)
      log_warn "reload requested via ctl.sh - not acknowledged by dnscrypt-proxy, restarting it instead"
      cmd_restart | sed 's/^ok=/restart_ok=/'
      if is_listening; then echo "ok=1"; else echo "ok=0"; fi
      echo "method=restart"
      ;;
    *)
      echo "ok=0"
      echo "error=dnscrypt-proxy is not running"
      return 1
      ;;
  esac
}

# ── reapply-rules: put the iptables rules back ──────────────────────────────
# Only while the daemon is listening; installing the redirect in front of a
# dead daemon black-holes DNS.
cmd_reapply_rules() {
  if is_paused; then
    echo "ok=0"
    echo "error=protection is paused - resume it instead"
    return 1
  fi
  if ! is_listening; then
    echo "ok=0"
    echo "error=dnscrypt-proxy is not listening - not installing a redirect to nothing"
    return 1
  fi
  rules_install_dns
  [ "$QUIC_BLOCK" = "1" ] && rules_install_quic
  log_info "rules reapplied via ctl.sh"
  echo "rules_present=$(yn rules_dns_present)"
  echo "ok=1"
}

# ── metrics: the daemon's own monitoring API, as JSON ───────────────────────
fetch_metrics_json() {
  if command -v curl >/dev/null 2>&1; then
    curl -sf --max-time 4 --connect-timeout 2 "$METRICS_URL" 2>/dev/null && return 0
  fi
  if [ -n "$BB" ]; then
    "$BB" wget -q -T 4 -O - "$METRICS_URL" 2>/dev/null && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q -T 4 -O - "$METRICS_URL" 2>/dev/null && return 0
  fi
  return 1
}

# ── poll: everything the dashboard needs, in one round trip ─────────────────
# Cheap by design - it runs every few seconds while the WebUI is open. The
# expensive checks (iptables, settings) are in `status`, which the System
# tab asks for less often.
cmd_poll() {
  _now=$(mono_now)
  _dp=$(daemon_pid)
  _started=$(health_get daemon_started)
  _tick=$(health_get tick_at)
  _res=$(health_get resolved_at)
  echo "watchdog=$([ -n "$(watchdog_pid)" ] && echo running || echo stopped)"
  echo "daemon=$([ -n "$_dp" ] && echo running || echo stopped)"
  echo "daemon_pid=$_dp"
  if [ -n "$_dp" ] && [ "${_started:-0}" -gt 0 ]; then echo "daemon_uptime=$((_now - _started))"; else echo "daemon_uptime=0"; fi
  echo "state=$(health_get state)"
  echo "liveness=$(health_get liveness)"
  echo "resolving=$(health_get resolving)"
  echo "failsafe=$(health_get failsafe)"
  echo "paused_left=$(pause_left)"
  if [ "${_res:-0}" -gt 0 ]; then echo "resolved_ago=$((_now - _res))"; else echo "resolved_ago="; fi
  if [ "${_tick:-0}" -gt 0 ]; then echo "tick_age=$((_now - _tick))"; else echo "tick_age="; fi
  echo "blocklist_domains=$(blocklist_domains)"
  echo "blocklist_updated=$(cat "$LAST_UPDATE_FILE" 2>/dev/null)"
  echo "update_running=$(update_running && echo 1 || echo 0)"
  _pq=0; [ -f "$PROBE_COUNT_FILE" ] && read -r _pq 2>/dev/null < "$PROBE_COUNT_FILE"
  case "$_pq" in '' | *[!0-9]*) _pq=0 ;; esac
  echo "probe_queries=$_pq"
  echo "ip_mode_effective=$(ip_mode_applied)"
  echo "version=$(sed -n 's/^version=//p' "$MODPROP" 2>/dev/null)"
  echo "@@METRICS@@"
  fetch_metrics_json || echo "{}"
  unset _now _dp _started _tick _res _pq
}

# ── update: blocklist download, run detached ────────────────────────────────
cmd_update() {
  case "$1" in
    start)
      if update_running; then
        echo "ok=0"; echo "error=an update is already running"; return 1
      fi
      if [ ! -f "$MODDIR/update-blocklist.sh" ]; then
        echo "ok=0"; echo "error=update-blocklist.sh missing"; return 1
      fi
      start_update_worker
      log_info "blocklist update started via ctl.sh"
      echo "ok=1"
      ;;
    poll)
      echo "running=$(update_running && echo 1 || echo 0)"
      echo "last_update=$(cat "$LAST_UPDATE_FILE" 2>/dev/null)"
      echo "@@LOG@@"
      tail -n 150 "$ACTION_LOG" 2>/dev/null
      ;;
    *)
      echo "ok=0"; echo "error=usage: update start|poll"; return 2
      ;;
  esac
}

# ── blocklist sources ────────────────────────────────────────────────────────
# One line per source, pipe-separated, for the WebUI picker:
#   src=id|group|label|selected|cached rules|cached date|description|url
# plus the per-source result of the last update:
#   report=id|status|rules|note
cmd_sources() {
  echo "auto=$BLOCKLIST_AUTO"
  echo "selected=$BLOCKLIST_SOURCES"
  echo "last_update=$(cat "$LAST_UPDATE_FILE" 2>/dev/null)"
  echo "update_running=$(update_running && echo 1 || echo 0)"
  # Wall-clock epochs, so the WebUI can show when the next automatic
  # update is due. auto_last = last successful update, auto_attempt = last
  # try of any kind, now = the device clock right now.
  echo "auto_last=$(cat "$BL_LAST_EPOCH" 2>/dev/null)"
  echo "auto_attempt=$(cat "$BL_LAST_ATTEMPT" 2>/dev/null)"
  echo "now=$(date +%s)"
  _sel=",$BLOCKLIST_SOURCES,"
  bl_all_sources | while IFS='|' read -r _id _grp _lbl _url _min _desc; do
    [ -n "$_id" ] || continue
    case "$_sel" in *",$_id,"*) _on=1 ;; *) _on=0 ;; esac
    # .meta is "date|count". Read with IFS, never a | inside ${x%%...}: in mksh (the
    # shell ksu.exec runs) a | inside a pattern is alternation, and both
    # fields came out empty for every source.
    _date=""; _n=""
    [ -f "$BL_SRC_DIR/$_id.meta" ] && IFS='|' read -r _date _n 2>/dev/null < "$BL_SRC_DIR/$_id.meta"
    echo "src=$_id|$_grp|$_lbl|$_on|$_n|$_date|$_desc|$_url"
  done
  if [ -f "$BL_SRC_DIR/legacy.txt" ]; then
    _date=""; _n=""
    [ -f "$BL_SRC_DIR/legacy.meta" ] && IFS='|' read -r _date _n 2>/dev/null < "$BL_SRC_DIR/legacy.meta"
    echo "legacy=$_n|$_date"
  fi
  [ -f "$BL_REPORT" ] && sed 's/^/report=/' "$BL_REPORT"
  echo "ok=1"
  unset _sel _id _grp _lbl _url _min _desc _on _date _n
}

cmd_sources_set() { # <comma-separated ids>
  _want=$(printf '%s' "$1" | tr ',' '\n')
  _valid=""
  for _id in $_want; do
    [ "$_id" = "none" ] && continue
    [ -n "$(bl_field "$_id" 1)" ] || { echo "ok=0"; echo "error=unknown source: $_id"; return 1; }
    case ",$_valid," in *",$_id,"*) : ;; *) _valid="${_valid:+$_valid,}$_id" ;; esac
  done
  # An empty selection is allowed (custom list only); store it as "none".
  set_setting BLOCKLIST_SOURCES "${_valid:-none}" || { echo "ok=0"; echo "error=could not write settings"; return 1; }
  BLOCKLIST_SOURCES="${_valid:-none}"
  log_info "blocklist sources set to: ${_valid:-none (custom list only)}"
  echo "selected=${_valid:-none}"
  echo "ok=1"
  unset _want _valid _id
}

cmd_sources_add_url() { # <https url>
  case "$1" in
    https://?*) : ;;
    *) echo "ok=0"; echo "error=the URL must start with https://"; return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9._~:/?#@!\&+,=%-]*) echo "ok=0"; echo "error=the URL contains characters that are not allowed"; return 1 ;;
  esac
  [ "${#1}" -le 512 ] || { echo "ok=0"; echo "error=the URL is too long"; return 1; }
  mkdir -p "$DATA_DIR"
  if grep -qxF "$1" "$BL_CUSTOM_URLS" 2>/dev/null; then
    echo "ok=0"; echo "error=that URL is already in the list"; return 1
  fi
  echo "$1" >> "$BL_CUSTOM_URLS"
  bl_catalog_reset
  _nid=$(bl_url_id "$1")
  cmd_sources_set "${BLOCKLIST_SOURCES:+$BLOCKLIST_SOURCES,}$_nid" > /dev/null
  log_info "custom blocklist source added: $1"
  echo "id=$_nid"
  echo "ok=1"
  unset _nid
}

cmd_sources_del_url() { # <url-id>
  _durl=$(bl_field "$1" 4)
  case "$1" in url-*) : ;; *) _durl="" ;; esac
  [ -n "$_durl" ] || { echo "ok=0"; echo "error=no custom source with id $1"; return 1; }
  grep -vxF "$_durl" "$BL_CUSTOM_URLS" > "$BL_CUSTOM_URLS.tmp" 2>/dev/null
  mv -f "$BL_CUSTOM_URLS.tmp" "$BL_CUSTOM_URLS"
  rm -f "$BL_SRC_DIR/$1.txt" "$BL_SRC_DIR/$1.meta"
  _rest=$(printf '%s' "$BLOCKLIST_SOURCES" | tr ',' '\n' | grep -vx "$1" | tr '\n' ',' | sed 's/,$//')
  bl_catalog_reset
  cmd_sources_set "$_rest" > /dev/null
  log_info "custom blocklist source removed: $_durl"
  echo "ok=1"
  unset _durl _rest
}

cmd_auto_set() { # off | daily | weekly
  case "$1" in
    off | daily | weekly) : ;;
    *) echo "ok=0"; echo "error=use off, daily or weekly"; return 1 ;;
  esac
  set_setting BLOCKLIST_AUTO "$1" || { echo "ok=0"; echo "error=could not write settings"; return 1; }
  log_info "automatic blocklist update: $1"
  echo "auto=$1"
  echo "ok=1"
}

# ── ipmode-set: switch the IP mode now ───────────────────────────────────────
cmd_ipmode_set() { # ipv4 | compat | dual
  case "$1" in
    ipv4 | compat | dual) : ;;
    *) echo "ok=0"; echo "error=use ipv4, compat or dual"; return 1 ;;
  esac
  if [ "$1" != "ipv4" ] && [ -z "$(watchdog_pid)" ]; then
    echo "ok=0"; echo "error=watchdog is not running - reboot first"; return 1
  fi
  set_setting IP_MODE "$1" || { echo "ok=0"; echo "error=could not write settings"; return 1; }
  _was=$(ip_mode_applied)
  IP_MODE=$1
  apply_ip_mode
  _restarted=0
  if [ "$APPLY_RESTART" = "1" ] && is_listening && [ -n "$(watchdog_pid)" ]; then
    log_info "restarting dnscrypt-proxy for the new IP mode"
    stop_daemon
    _i=0
    while [ "$_i" -lt 45 ] && ! is_listening; do sleep 1; _i=$((_i + 1)); done
    _restarted=1
  fi
  echo "ip_mode=$IP_MODE"
  echo "ip_mode_effective=$(ip_mode_applied)"
  echo "ip6_nat=$(yn have_ip6_nat)"
  echo "restarted=$_restarted"
  echo "listening=$(yn is_listening)"
  # Coming out of IPv4-only: make sure Android picks IPv6 up again (see
  # net_refresh_for_ipv6). Detached - it can take ~15s and may reconnect.
  _nr=0
  case "$_was" in
    ipv4 | none)
      if [ "$IP_MODE" != "ipv4" ]; then
        setsid sh "$MODDIR/ctl.sh" net-refresh-v6 < /dev/null > /dev/null 2>&1 &
        _nr=1
      fi ;;
  esac
  echo "net_refresh=$_nr"
  if is_listening; then echo "ok=1"; else echo "ok=0"; echo "error=dnscrypt-proxy did not come back - see the log"; fi
  unset _restarted _i _was _nr
}

# ── reload with fallback, shared by the rule commands ───────────────────────
reload_or_restart() {
  reload_daemon
  case $? in
    0) echo "applied=reload" ;;
    1) log_warn "reload not acknowledged - restarting dnscrypt-proxy"
       stop_daemon
       echo "applied=restart" ;;
    *) echo "applied=next-start" ;;
  esac
}

# ── check: is a domain blocked, by what, and what does the daemon say ───────
cmd_check() { # <domain>
  _d=$(valid_domain "$1") || { echo "ok=0"; echo "error=not a valid domain name"; return 1; }
  echo "domain=$_d"
  _al=$(rule_match "$_d" "$ALLOW_FILE")
  _bl=$(rule_match "$_d" "$BLOCKLIST")
  echo "allowed_rule=$_al"
  echo "blocked_rule=$_bl"
  if [ -n "$_bl" ]; then
    echo "blocked_by=$(rule_origins "$_bl" | tr '\n' ',' | sed 's/,$//')"
  fi
  if [ -n "$_al" ]; then echo "verdict=allowed"
  elif [ -n "$_bl" ]; then echo "verdict=blocked"
  else echo "verdict=not_blocked"
  fi
  echo "in_allow=$(_has_rule "$ALLOW_FILE" "$_d" && echo 1 || echo 0)"
  echo "in_custom=$(_has_rule "$BL_CUSTOM" "$_d" && echo 1 || echo 0)"
  if is_listening; then live_query "$_d"; else echo "live=down"; fi
  echo "ok=1"
  unset _d _al _bl
}

cmd_allow() { # <domain>
  _d=$(valid_domain "$1") || { echo "ok=0"; echo "error=not a valid domain name"; return 1; }
  if _has_rule "$ALLOW_FILE" "$_d"; then
    echo "ok=1"; echo "note=already allowed"; unset _d; return 0
  fi
  _append_rule "$ALLOW_FILE" "$_d"
  mirror_to_sd allowed-names.txt
  log_info "allowed via WebUI: $_d"
  reload_or_restart
  echo "ok=1"
  unset _d
}

cmd_unallow() { # <domain>
  _d=$(valid_domain "$1") || { echo "ok=0"; echo "error=not a valid domain name"; return 1; }
  _remove_rule "$ALLOW_FILE" "$_d" || { echo "ok=0"; echo "error=$_d is not in the allow list"; unset _d; return 1; }
  mirror_to_sd allowed-names.txt
  log_info "removed from the allow list via WebUI: $_d"
  reload_or_restart
  echo "ok=1"
  unset _d
}

# Blocking is instant: the rule goes into the custom list (so it survives
# every future rebuild) and straight onto the end of the live list, then a
# reload. No rebuild needed for an addition.
cmd_block() { # <domain>
  _d=$(valid_domain "$1") || { echo "ok=0"; echo "error=not a valid domain name"; return 1; }
  if ! _has_rule "$BL_CUSTOM" "$_d"; then
    _append_rule "$BL_CUSTOM" "$_d"
    mirror_to_sd custom-blocked-names.txt
  fi
  _append_rule "$BLOCKLIST" "$_d"
  log_info "blocked via WebUI: $_d"
  if _has_rule "$ALLOW_FILE" "$_d"; then echo "warning=$_d is also in the allow list, which wins - remove it there to block"; fi
  reload_or_restart
  echo "ok=1"
  unset _d
}

# Unblocking needs a rebuild (to take the rule back out of the live list).
# If a downloaded source blocks the name too, it stays blocked - say so.
cmd_unblock() { # <domain>
  _d=$(valid_domain "$1") || { echo "ok=0"; echo "error=not a valid domain name"; return 1; }
  _remove_rule "$BL_CUSTOM" "$_d" || { echo "ok=0"; echo "error=$_d is not in your custom list"; unset _d; return 1; }
  mirror_to_sd custom-blocked-names.txt
  log_info "removed from the custom list via WebUI: $_d"
  bl_rebuild_custom
  case $? in
    0) reload_or_restart ;;
    2) echo "applied=after-running-job" ;;
    *) echo "ok=0"; echo "error=rebuild failed - see the log"; unset _d; return 1 ;;
  esac
  _still=$(rule_match "$_d" "$BLOCKLIST")
  [ -n "$_still" ] && echo "still_blocked_by=$_still ($(rule_origins "$_still" | tr '\n' ',' | sed 's/,$//'))"
  echo "ok=1"
  unset _d _still
}

cmd_rules_list() {
  if [ -f "$ALLOW_FILE" ]; then
    sed 's/\r$//; s/[ \t]*#.*$//; s/^[ \t]*//; s/[ \t]*$//' "$ALLOW_FILE" | grep -v '^$' | sed 's/^/allow=/'
  fi
  if [ -f "$BL_CUSTOM" ]; then
    sed 's/\r$//; s/[ \t]*#.*$//; s/^[ \t]*//; s/[ \t]*$//' "$BL_CUSTOM" | grep -v '^$' | sed 's/^/block=/'
  fi
  echo "ok=1"
}

# ── pause / resume ───────────────────────────────────────────────────────────
cmd_pause() { # <minutes 1-240>
  case "$1" in '' | *[!0-9]*) echo "ok=0"; echo "error=minutes must be a number"; return 1 ;; esac
  if [ "$1" -lt 1 ] || [ "$1" -gt 240 ]; then echo "ok=0"; echo "error=1 to 240 minutes"; return 1; fi
  echo $(( $(mono_now) + $1 * 60 )) > "$PAUSE_FILE"
  rules_remove_dns
  log_warn "protection PAUSED for $1 min - DNS goes out unencrypted until it resumes"
  echo "paused_left=$(pause_left)"
  echo "ok=1"
}

cmd_resume() {
  rm -f "$PAUSE_FILE"
  if is_listening; then
    rules_install_dns
    [ "$QUIC_BLOCK" = "1" ] && rules_install_quic
  fi
  log_info "protection resumed"
  echo "ok=1"
}

# ── set: the settings the WebUI exposes as switches ─────────────────────────
cmd_set() { # <KEY> <VALUE>
  case "$1" in
    QUIC_BLOCK | HEALTH_RESTART | IPV6_PER_IFACE_ENFORCE)
      case "$2" in 0 | 1) : ;; *) echo "ok=0"; echo "error=$1 takes 0 or 1"; return 1 ;; esac ;;
    LOG_KEEP_LINES)
      case "$2" in '' | *[!0-9]*) echo "ok=0"; echo "error=a number"; return 1 ;; esac
      if [ "$2" -lt 100 ] || [ "$2" -gt 20000 ]; then echo "ok=0"; echo "error=100 to 20000"; return 1; fi ;;
    *) echo "ok=0"; echo "error=$1 cannot be set here"; return 1 ;;
  esac
  set_setting "$1" "$2" || { echo "ok=0"; echo "error=could not write settings"; return 1; }
  # Effects that should not wait for the watchdog's next look.
  if [ "$1" = "QUIC_BLOCK" ]; then
    if [ "$2" = "1" ]; then rules_install_quic; else rules_remove_quic; fi
  fi
  log_info "setting changed via WebUI: $1=$2"
  echo "$1=$2"
  echo "ok=1"
}

# ── private-dns-off: Android's own DNS-over-TLS goes around the redirect ────
cmd_private_dns_off() {
  settings put global private_dns_mode off 2>/dev/null
  _pd=$(settings get global private_dns_mode 2>/dev/null)
  if [ "$_pd" = "off" ]; then
    log_info "Android Private DNS turned off via WebUI"
    echo "private_dns=off"; echo "ok=1"
  else
    echo "ok=0"; echo "error=Android did not accept the change (now: ${_pd:-unknown})"
  fi
  unset _pd
}

# ── resolvers ────────────────────────────────────────────────────────────────
cmd_resolvers() {
  res_list
  echo "ok=1"
}

cmd_resolvers_search() { # <term>
  _t=$(printf '%s' "$1" | tr -dc 'A-Za-z0-9._ -')
  [ "${#_t}" -ge 2 ] || { echo "ok=0"; echo "error=type at least 2 characters"; unset _t; return 1; }
  res_search "$_t" | while IFS= read -r _n; do
    _st=$(res_stamp "$_n")
    [ -n "$_st" ] && echo "res=$_n|0|0|$(res_decode "$_st")|$(res_desc "$_n" | tr '|' '/')"
  done
  echo "ok=1"
  unset _t
}

_res_validate() { # <csv> -> sets RES_NAMES
  RES_NAMES=""
  for _n in $(printf '%s' "$1" | tr ',' ' '); do
    case "$_n" in *[!A-Za-z0-9._-]*) echo "ok=0"; echo "error=bad name: $_n"; return 1 ;; esac
    res_exists "$_n" || { echo "ok=0"; echo "error=unknown resolver: $_n"; return 1; }
    case " $RES_NAMES " in *" $_n "*) : ;; *) RES_NAMES="$RES_NAMES $_n" ;; esac
  done
  unset _n
  [ -n "$RES_NAMES" ] || { echo "ok=0"; echo "error=select at least one resolver"; return 1; }
  return 0
}

cmd_resolvers_set() { # <csv>
  _res_validate "$1" || return 1
  # shellcheck disable=SC2086
  set -- $RES_NAMES
  [ "$#" -le 8 ] || { echo "ok=0"; echo "error=8 resolvers at most"; return 1; }
  [ -n "$(watchdog_pid)" ] || { echo "ok=0"; echo "error=watchdog is not running"; return 1; }
  res_apply "$@" || { echo "ok=0"; echo "error=config check failed: $RES_ERROR"; return 1; }
  log_info "resolvers set via WebUI: $*"
  stop_daemon
  _i=0
  while [ "$_i" -lt 45 ] && ! is_listening; do sleep 1; _i=$((_i + 1)); done
  if ! is_listening && [ -f "$DATA_DIR/dnscrypt-proxy.toml.bak" ]; then
    # The daemon would not come up with the new servers: put the old
    # config back rather than leave DNS to the failsafe.
    mv -f "$DATA_DIR/dnscrypt-proxy.toml.bak" "$CONFIG"
    mirror_to_sd dnscrypt-proxy.toml
    log_warn "dnscrypt-proxy did not start with the new resolvers - restored the previous ones"
    stop_daemon
    echo "ok=0"; echo "error=dnscrypt-proxy did not start with those resolvers - restored the previous ones"
    unset _i
    return 1
  fi
  echo "took=$_i"
  echo "ok=1"
  unset _i
}

cmd_resolvers_test() { # <csv>
  _res_validate "$1" || return 1
  # shellcheck disable=SC2086
  res_latency $RES_NAMES | sed 's/^/lat=/'
  echo "ok=1"
}

# ── log ──────────────────────────────────────────────────────────────────────
cmd_log() {
  _n=${1:-200}
  case "$_n" in '' | *[!0-9]*) _n=200 ;; esac
  tail -n "$_n" "$LOG" 2>/dev/null
  unset _n
}

cmd_log_clear() {
  : > "$LOG" 2>/dev/null
  log_info "log cleared via ctl.sh"
  echo "ok=1"
}

usage() {
  cat <<'EOF'
usage: ctl.sh <command>

  status          full state as key=value
  poll            quick state + daemon metrics JSON (for the dashboard)
  probe           run the liveness and resolution checks now
  restart         restart dnscrypt-proxy (watchdog brings it back)
  reload          re-read lists without downtime (SIGHUP)
  reapply-rules   reinstall the iptables rules
  update start    start a blocklist download (detached)
  update poll     progress of the running download
  sources         blocklist sources, selection and last results
  sources-set IDS select sources (comma-separated ids)
  sources-add-url URL / sources-del-url ID   manage your own list URLs
  auto-set MODE   automatic update: off | daily | weekly
  ipmode-set M    IP mode: ipv4 | compat | dual (applied immediately)
  check D         is domain D blocked, by which rule and list; live answer
  allow D / unallow D / block D / unblock D   your own rules, applied now
  rules-list      your allow and custom-block rules
  pause MIN / resume   take DNS protection down for 1-240 minutes
  set KEY VALUE   QUIC_BLOCK, HEALTH_RESTART, IPV6_PER_IFACE_ENFORCE (0/1),
                  LOG_KEEP_LINES (100-20000)
  resolvers / resolvers-search T / resolvers-set A,B / resolvers-test A,B
  private-dns-off turn Android Private DNS off (it bypasses the redirect)
  net-refresh-v6  reconnect Wi-Fi / mobile data if Android missed IPv6
  log [N]         last N log lines (default 200)
  log-clear       empty the log
EOF
}

cmd=$1
[ $# -gt 0 ] && shift
case "$cmd" in
  status)        cmd_status ;;
  poll)          cmd_poll ;;
  metrics)       fetch_metrics_json ;;
  update)        cmd_update "$1" ;;
  sources)       cmd_sources ;;
  sources-set)   cmd_sources_set "$1" ;;
  sources-add-url) cmd_sources_add_url "$1" ;;
  sources-del-url) cmd_sources_del_url "$1" ;;
  auto-set)      cmd_auto_set "$1" ;;
  ipmode-set)    cmd_ipmode_set "$1" ;;
  check)         cmd_check "$1" ;;
  allow)         cmd_allow "$1" ;;
  unallow)       cmd_unallow "$1" ;;
  block)         cmd_block "$1" ;;
  unblock)       cmd_unblock "$1" ;;
  rules-list)    cmd_rules_list ;;
  pause)         cmd_pause "$1" ;;
  resume)        cmd_resume ;;
  set)           cmd_set "$1" "$2" ;;
  resolvers)     cmd_resolvers ;;
  resolvers-search) cmd_resolvers_search "$1" ;;
  resolvers-set) cmd_resolvers_set "$1" ;;
  resolvers-test) cmd_resolvers_test "$1" ;;
  probe)         cmd_probe ;;
  private-dns-off) cmd_private_dns_off ;;
  net-refresh-v6) net_refresh_for_ipv6; echo "ok=1" ;;
  restart)       cmd_restart ;;
  reload)        cmd_reload ;;
  reapply-rules) cmd_reapply_rules ;;
  log)           cmd_log "$1" ;;
  log-clear)     cmd_log_clear ;;
  -h | --help | help | '') usage; exit 2 ;;
  *) echo "ok=0"; echo "error=unknown command: $cmd"; usage >&2; exit 2 ;;
esac
