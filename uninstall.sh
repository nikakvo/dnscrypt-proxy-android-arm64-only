#!/system/bin/sh

(
# -----------------------------------------------
# Wait until system is fully booted
# and storage is accessible
# -----------------------------------------------
WAIT=0
while [ "$(getprop sys.boot_completed)" != "1" ] || \
      [ ! -d "/storage/emulated/0/Android" ]; do
  sleep 1
  WAIT=$((WAIT + 1))
  [ "$WAIT" -ge 60 ] && break
done

# ===============================================
# STEP 1: Kill dnscrypt-proxy process
# Must be done first before removing anything
# ===============================================
if pgrep -x dnscrypt-proxy >/dev/null 2>&1; then
  pkill -x dnscrypt-proxy 2>/dev/null
  sleep 2
  # Force kill if still running
  pkill -9 -x dnscrypt-proxy 2>/dev/null
fi

# ===============================================
# STEP 1a: Kill busybox httpd (CGI control server)
# Started by service.sh on 127.0.0.1:5556 to serve
# the Web UI's Update Blocklist button + cgi-bin/
# Also kill any in-progress update-blocklist.sh run.
# ===============================================
# Kill only OUR httpd, via the pidfile service.sh writes.
# A blanket `pkill -f "busybox httpd"` also killed the control
# server of any other module using busybox httpd for its WebUI.
HTTPD_PIDFILE="/data/adb/dnscrypt-proxy-state/httpd.pid"
if [ -f "$HTTPD_PIDFILE" ]; then
  HPID=$(cat "$HTTPD_PIDFILE" 2>/dev/null)
  if [ -n "$HPID" ] && [ -d "/proc/$HPID" ]; then
    case "$(tr '\0' ' ' < "/proc/$HPID/cmdline" 2>/dev/null)" in
      *httpd*5556*) kill "$HPID" 2>/dev/null; sleep 1; kill -9 "$HPID" 2>/dev/null ;;
    esac
  fi
  unset HPID
fi
pkill -f "update-blocklist\.sh" 2>/dev/null
sleep 1

# ===============================================
# STEP 1a-2: Backward-compat cleanup for the
# blocklist auto-update feature (removed as of this
# version). Older installs may still have the loop
# process running and its flag/pid/schedule files on
# disk - kill and remove them so nothing lingers after
# uninstall.
# ===============================================
pkill -f "auto-update-loop\.sh" 2>/dev/null
rm -f /data/adb/dnscrypt-autoupdate.flag
rm -f /data/adb/dnscrypt-autoupdate.pid
rm -f /data/adb/dnscrypt-autoupdate-next.txt

# ===============================================
# STEP 1b: Remove webroot metrics files
# service.sh writes metrics.json (and .tmp on
# in-progress fetch) to the module webroot dir.
# Clean them up so no stale data is left behind.
# Also cleans query.log if still present from
# old builds that used the rolling window approach.
# ===============================================
MODDIR="/data/adb/modules/dnscrypt-proxy-android"
rm -f "$MODDIR/webroot/metrics.json"     2>/dev/null
rm -f "$MODDIR/webroot/metrics.json.tmp" 2>/dev/null
rm -f "$MODDIR/webroot/query.log"        2>/dev/null
rm -f "$MODDIR/webroot/query.log.tmp"    2>/dev/null
unset MODDIR

# ===============================================
# STEP 2: Remove iptables DROP rules
# These were set by post-fs-data.sh to block
# DNS during boot until dnscrypt was ready
# ===============================================
iptables -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null
iptables -D OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null

# ===============================================
# STEP 3: Remove iptables NAT redirect rules
# These redirected all DNS to dnscrypt on :5354
# ===============================================
iptables -t nat -D OUTPUT -p tcp --dport 53 -j DNAT --to-destination 127.0.0.1:5354 2>/dev/null
iptables -t nat -D OUTPUT -p udp --dport 53 -j DNAT --to-destination 127.0.0.1:5354 2>/dev/null

# ===============================================
# STEP 3b: Remove QUIC block rule
# post-fs-data.sh added this to prevent DNS
# policy bypass via Chrome/YouTube QUIC/DoH
# ===============================================
iptables -D OUTPUT -p udp --dport 443 -j DROP 2>/dev/null

# ===============================================
# STEP 4: Restore ip6tables to default
# post-fs-data.sh set DROP policy on all chains
# and blocked all IPv6 traffic except loopback
# ===============================================

# Remove loopback accept rules first
ip6tables -D INPUT  -i lo -j ACCEPT 2>/dev/null
ip6tables -D OUTPUT -o lo -j ACCEPT 2>/dev/null

# Restore default ACCEPT policy on all chains
# Loopback rules not needed — ACCEPT policy covers everything
ip6tables -P INPUT   ACCEPT 2>/dev/null
ip6tables -P OUTPUT  ACCEPT 2>/dev/null
ip6tables -P FORWARD ACCEPT 2>/dev/null

# ===============================================
# STEP 5: Restore IPv6 kernel settings
# post-fs-data.sh and service.sh disabled IPv6
# via sysctl and resetprop
# ===============================================

# Restore sysctl values
echo 0 > /proc/sys/net/ipv6/conf/all/disable_ipv6     2>/dev/null
echo 0 > /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null
echo 1 > /proc/sys/net/ipv6/conf/all/accept_ra        2>/dev/null
echo 1 > /proc/sys/net/ipv6/conf/default/accept_ra    2>/dev/null

# Remove Android properties set by resetprop
resetprop --delete net.ipv6.conf.all.disable_ipv6      2>/dev/null
resetprop --delete net.ipv6.conf.default.disable_ipv6  2>/dev/null
resetprop --delete net.ipv6.conf.all.accept_redirects  2>/dev/null
resetprop --delete net.ipv6.conf.default.accept_redirects 2>/dev/null
resetprop --delete net.ipv6.conf.lo.disable_ipv6       2>/dev/null

# ===============================================
# STEP 6: Restore Android Private DNS
# customize.sh set this to 'off'
# Restore to Android default (opportunistic)
# ===============================================
settings put global private_dns_mode opportunistic 2>/dev/null

# ===============================================
# STEP 7: Remove dnscrypt-proxy config directory
# NOTE: This also removes .bak backup files that
# customize.sh created. By design — full uninstall.
# All known storage mount points
# ===============================================
rm -rf /storage/emulated/0/dnscrypt-proxy
rm -rf /sdcard/dnscrypt-proxy
rm -rf /data/media/0/dnscrypt-proxy
rm -rf /mnt/runtime/default/emulated/0/dnscrypt-proxy
rm -rf /mnt/runtime/full/emulated/0/dnscrypt-proxy
rm -rf /mnt/runtime/read/emulated/0/dnscrypt-proxy
rm -rf /mnt/runtime/write/emulated/0/dnscrypt-proxy
rm -rf /storage/self/primary/dnscrypt-proxy

# ===============================================
# STEP 8: Remove log files
# ===============================================
rm -f /data/adb/dnscrypt-proxy.log
rm -f /data/adb/dnscrypt-action.log

# ===============================================
# STEP 9: Remove settings and runtime state
# Both live outside $MODDIR so they survive module
# updates - which means only we can clean them up.
# ===============================================
rm -f  /data/adb/dnscrypt-proxy-android.conf
rm -rf /data/adb/dnscrypt-proxy-state

) &
