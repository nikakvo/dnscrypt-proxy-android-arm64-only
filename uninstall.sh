#!/system/bin/sh

(
# -----------------------------------------------
# Wait until system is fully booted and storage is accessible
# -----------------------------------------------
WAIT=0
while [ "$(getprop sys.boot_completed)" != "1" ] || \
      [ ! -d "/storage/emulated/0/Android" ]; do
  sleep 1
  WAIT=$((WAIT + 1))
  [ "$WAIT" -ge 60 ] && break
done

DNS_REDIR="127.0.0.1:5354"
BOOTSTRAP_IPS="9.9.9.9 149.112.112.112 45.11.45.11"

# ===============================================
# STEP 1: Kill dnscrypt-proxy
# ===============================================
if pgrep -x dnscrypt-proxy >/dev/null 2>&1; then
  pkill -x dnscrypt-proxy 2>/dev/null
  sleep 2
  pkill -9 -x dnscrypt-proxy 2>/dev/null
fi

# ===============================================
# STEP 1a: Kill busybox httpd (CGI control server of r11 and earlier)
# Only OUR instance, via the pidfile service.sh writes, so a blanket
# `pkill -f "busybox httpd"` cannot take down the WebUI server of
# another module using busybox httpd.
# ===============================================
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

# Backward-compat: the removed auto-update loop from older builds
pkill -f "auto-update-loop\.sh" 2>/dev/null
rm -f /data/adb/dnscrypt-autoupdate.flag
rm -f /data/adb/dnscrypt-autoupdate.pid
rm -f /data/adb/dnscrypt-autoupdate-next.txt

# ===============================================
# STEP 1b: Remove webroot runtime files
# ===============================================
MODDIR="/data/adb/modules/dnscrypt-proxy-android"
rm -f "$MODDIR/webroot/metrics.json"     2>/dev/null
rm -f "$MODDIR/webroot/metrics.json.tmp" 2>/dev/null
rm -f "$MODDIR/webroot/query.log"        2>/dev/null
rm -f "$MODDIR/webroot/query.log.tmp"    2>/dev/null
unset MODDIR

# ===============================================
# STEP 2: Remove all DNS rules (r11 set + legacy r10 set)
# ===============================================
iptables -t nat -D OUTPUT -p tcp --dport 53 -j DNAT --to-destination "$DNS_REDIR" 2>/dev/null
iptables -t nat -D OUTPUT -p udp --dport 53 -j DNAT --to-destination "$DNS_REDIR" 2>/dev/null
iptables -D OUTPUT ! -o lo -p tcp --dport 53 -j DROP 2>/dev/null
iptables -D OUTPUT ! -o lo -p udp --dport 53 -j DROP 2>/dev/null
ip6tables -D OUTPUT ! -o lo -p tcp --dport 53 -j DROP 2>/dev/null
ip6tables -D OUTPUT ! -o lo -p udp --dport 53 -j DROP 2>/dev/null
for IP in $BOOTSTRAP_IPS; do
  iptables -t nat -D OUTPUT -p tcp -d "$IP" --dport 53 -m owner --uid-owner 0 -j RETURN 2>/dev/null
  iptables -t nat -D OUTPUT -p udp -d "$IP" --dport 53 -m owner --uid-owner 0 -j RETURN 2>/dev/null
  iptables -D OUTPUT ! -o lo -p tcp -d "$IP" --dport 53 -m owner --uid-owner 0 -j ACCEPT 2>/dev/null
  iptables -D OUTPUT ! -o lo -p udp -d "$IP" --dport 53 -m owner --uid-owner 0 -j ACCEPT 2>/dev/null
done

# IPv6 DNS redirect (IP modes compat / dual, r14+)
ip6tables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports 5354 2>/dev/null
ip6tables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 5354 2>/dev/null

# Legacy rules from r10 and earlier
iptables -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null
iptables -D OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null

# ===============================================
# STEP 3: Remove QUIC block (both families)
# ===============================================
iptables  -D OUTPUT -p udp --dport 443 -j DROP 2>/dev/null
ip6tables -D OUTPUT -p udp --dport 443 -j DROP 2>/dev/null

# ===============================================
# STEP 4: Restore ip6tables to default
# ===============================================
ip6tables -D INPUT  -i lo -j ACCEPT 2>/dev/null
ip6tables -D OUTPUT -o lo -j ACCEPT 2>/dev/null
ip6tables -P INPUT   ACCEPT 2>/dev/null
ip6tables -P OUTPUT  ACCEPT 2>/dev/null
ip6tables -P FORWARD ACCEPT 2>/dev/null

# ===============================================
# STEP 5: Restore IPv6 kernel settings
# ===============================================
echo 0 > /proc/sys/net/ipv6/conf/all/disable_ipv6     2>/dev/null
echo 0 > /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null
echo 1 > /proc/sys/net/ipv6/conf/all/accept_ra        2>/dev/null
echo 1 > /proc/sys/net/ipv6/conf/default/accept_ra    2>/dev/null

resetprop --delete net.ipv6.conf.all.disable_ipv6         2>/dev/null
resetprop --delete net.ipv6.conf.default.disable_ipv6     2>/dev/null
resetprop --delete net.ipv6.conf.all.accept_redirects     2>/dev/null
resetprop --delete net.ipv6.conf.default.accept_redirects 2>/dev/null
resetprop --delete net.ipv6.conf.lo.disable_ipv6          2>/dev/null

# ===============================================
# STEP 6: Restore Private DNS to whatever it was BEFORE install.
# r10 always wrote "opportunistic", which silently changed the setting
# for anyone who had deliberately turned it off.
# ===============================================
PREV_PDNS_FILE="/data/adb/dnscrypt-prev-private-dns"
if [ -f "$PREV_PDNS_FILE" ]; then
  PREV=$(cat "$PREV_PDNS_FILE" 2>/dev/null | tr -d '[:space:]')
  [ -n "$PREV" ] && settings put global private_dns_mode "$PREV" 2>/dev/null
  rm -f "$PREV_PDNS_FILE"
else
  settings put global private_dns_mode opportunistic 2>/dev/null
fi

# ===============================================
# STEP 7: Remove runtime and config directories
# ===============================================
rm -rf /data/adb/dnscrypt-proxy

rm -rf /storage/emulated/0/dnscrypt-proxy
rm -rf /sdcard/dnscrypt-proxy
rm -rf /data/media/0/dnscrypt-proxy
rm -rf /mnt/runtime/default/emulated/0/dnscrypt-proxy
rm -rf /mnt/runtime/full/emulated/0/dnscrypt-proxy
rm -rf /mnt/runtime/read/emulated/0/dnscrypt-proxy
rm -rf /mnt/runtime/write/emulated/0/dnscrypt-proxy
rm -rf /storage/self/primary/dnscrypt-proxy

# ===============================================
# STEP 8: Logs, settings and state
# ===============================================
rm -f /data/adb/dnscrypt-proxy.log
rm -f /data/adb/dnscrypt-action.log
rm -f /data/adb/dnscrypt-proxy-android.conf
rm -rf /data/adb/dnscrypt-proxy-state

) &
