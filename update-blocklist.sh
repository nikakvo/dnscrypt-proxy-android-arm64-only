#!/system/bin/sh
# update-blocklist.sh - download the selected blocklist sources and rebuild
# blocked-names.txt. Started detached by `ctl.sh update start` (the Update
# button, or the watchdog's auto-update); its output goes to
# /data/adb/dnscrypt-action.log, which the WebUI shows live.
#
# The real work lives in sh/blocklist.sh.

MODDIR=${0%/*}
if [ ! -f "$MODDIR/sh/common.sh" ] || [ ! -f "$MODDIR/sh/blocklist.sh" ]; then
  echo "! ERROR: module files missing - reflash the module."
  exit 1
fi
# shellcheck source=/dev/null
. "$MODDIR/sh/common.sh"
# shellcheck source=/dev/null
. "$MODDIR/sh/blocklist.sh"
load_settings

mkdir -p "$STATE_DIR" "$DATA_DIR"
echo $$ > "$UPDATE_PIDFILE"
rm -f "$UPDATE_PENDING"

# The EXIT trap cleans up; INT and TERM must also END the script. r12
# trapped all three with the cleanup alone, and a trapped signal whose
# handler does not exit is simply swallowed: the download went on after
# its lock and pid file had been removed.
_ub_cleanup() {
  [ "$(cat "$UPDATE_PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$UPDATE_PIDFILE"
  bl_unlock
}
# A shell runs a trap only once the command in the foreground returns, so
# a stop request can wait for the current network call (at most its
# --max-time). The download itself runs in the background; it and anything
# else this worker started are in its own session (setsid), and the whole
# group is taken down with it.
_ub_stop() { # <exit code>
  trap - EXIT INT TERM
  _ub_cleanup
  # Only as its own process group (started through setsid, as ctl.sh and
  # the watchdog do). Run by hand from another script, group 0 would
  # include the caller.
  _st=$(cat "/proc/$$/stat" 2>/dev/null); _st=${_st##*) }
  set -- "$1" $_st
  [ "$4" = "$$" ] && kill -TERM 0 2>/dev/null
  exit "$1"
}
trap '_ub_cleanup' EXIT
trap '_ub_stop 143' TERM
trap '_ub_stop 130' INT

echo " "
echo "************************************"
echo "*   DNSCrypt Blocklist Updater     *"
echo "************************************"
echo " "
echo "  Current list : $(blocklist_domains) rules"
echo "  Selected     : $(bl_selected | tr '\n' ' ')"
[ "$1" = "--auto" ] && echo "  Trigger      : automatic update"
echo " "

bl_sync_custom_from_sdcard() {
  _sd="$SD_DIR/custom-blocked-names.txt"
  [ -f "$_sd" ] || return 0
  if [ ! -f "$BL_CUSTOM" ] || [ "$(mtime_of "$_sd")" -gt "$(mtime_of "$BL_CUSTOM")" ]; then
    cp -f "$_sd" "$BL_CUSTOM" 2>/dev/null && echo "* Picked up a newer custom-blocked-names.txt from the sdcard"
  fi
  unset _sd
}
bl_sync_custom_from_sdcard

if ! bl_update; then
  echo " "
  echo "! ERROR: update failed - the current list is unchanged."
  exit 1
fi

echo " "
echo "* Reloading dnscrypt-proxy..."
reload_daemon
case $? in
  0) echo "* Reload confirmed - new list active, no downtime!" ;;
  1) echo "* dnscrypt-proxy did not acknowledge the reload - restarting it"
     log_warn "dnscrypt-proxy did not acknowledge the blocklist reload - restarting it"
     stop_daemon
     echo "* Restarted - the watchdog brings it back within ~10s." ;;
  *) echo "* dnscrypt-proxy is not running - the new list loads when it starts." ;;
esac

echo " "
echo "************************************"
echo "*           Done!                  *"
echo "************************************"
