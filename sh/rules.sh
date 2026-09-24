#!/system/bin/sh
# rules.sh - shared iptables/ip6tables rule definitions.
#
# Sourced by post-fs-data.sh and service.sh so the two can never drift
# apart. Nothing in here runs on its own; it only defines functions.
#
# -----------------------------------------------------------------
# DESIGN NOTES (r11) - why the rules look the way they do now
# -----------------------------------------------------------------
#
# 1. The DNAT redirect IS the boot-time block.
#    Up to r10 there was also a `filter OUTPUT -p udp --dport 53 -j DROP`
#    rule, meant to fail closed until the daemon was ready. It never once
#    fired. For locally generated packets the kernel walks nat OUTPUT
#    BEFORE filter OUTPUT, so by the time the DROP rule saw the packet its
#    destination port was already rewritten to 5354 and `--dport 53` no
#    longer matched. All the lift_dns_block() bookkeeping around it was
#    operating on a rule that did nothing.
#    What actually blocked DNS at boot was the redirect itself, pointing at
#    a port nobody was listening on yet. That is genuinely fail-closed
#    (the packet is delivered to loopback and dropped there, nothing
#    leaves the device), so it is now the only mechanism, stated plainly.
#
# 2. Rules are INSERTED at the top, not appended.
#    netd owns these chains and rebuilds them on every connectivity
#    change, VPN start, tethering toggle, etc. Appending put our redirect
#    below whatever netd had already installed. `-I OUTPUT 1` keeps it
#    first. service.sh also re-verifies on every tick instead of only
#    inside the is_listening branch.
#
# 3. The leak guard is scoped to non-loopback output.
#    `! -o lo -p udp --dport 53 -j DROP` only ever sees port-53 traffic
#    that escaped the NAT redirect - i.e. a real leak. Legitimate traffic
#    has already been rewritten to 127.0.0.1:5354 and goes out via lo, so
#    it never reaches this rule.
#
# 4. The daemon's own bootstrap traffic is exempted narrowly.
#    Only root-owned packets addressed to the three bootstrap_resolvers
#    skip the redirect. Not "all of uid 0" - that would let every root
#    process (including this module's own curl in update-blocklist.sh)
#    resolve outside the proxy in plaintext. With [sources] disabled in
#    the toml the daemon does not need this at all; it exists so that
#    re-enabling sources does not reintroduce the deadlock where
#    dnscrypt-proxy's bootstrap query got redirected into dnscrypt-proxy.
#
# 5. Loopback destinations are deliberately NOT exempted.
#    127.0.0.1:53 stays redirected to :5354, which is what lets the
#    watchdog probe the live daemon with a plain `nslookup example.com
#    127.0.0.1` instead of spawning a second dnscrypt-proxy process.

DNS_REDIR="127.0.0.1:5354"
BOOTSTRAP_IPS="9.9.9.9 149.112.112.112 45.11.45.11"
OWNER_FLAG_FILE="/data/adb/dnscrypt-proxy-state/owner_match_unavailable"

# -----------------------------------------------------------------
# Does this kernel have the xt_owner match? Some stripped GKI builds
# do not. Probe once, cache the answer for the boot.
# -----------------------------------------------------------------
have_owner_match() {
  [ -f "$OWNER_FLAG_FILE" ] && return 1
  [ -n "$OWNER_MATCH_OK" ] && return "$OWNER_MATCH_OK"
  if iptables -t nat -I OUTPUT 1 -p udp -d 127.0.0.2 --dport 53 \
       -m owner --uid-owner 0 -j RETURN 2>/dev/null; then
    iptables -t nat -D OUTPUT -p udp -d 127.0.0.2 --dport 53 \
       -m owner --uid-owner 0 -j RETURN 2>/dev/null
    OWNER_MATCH_OK=0
  else
    OWNER_MATCH_OK=1
    : > "$OWNER_FLAG_FILE" 2>/dev/null
  fi
  return "$OWNER_MATCH_OK"
}

# -----------------------------------------------------------------
# IPv6 DNS redirect (IP modes "compat" and "dual").
#
# ip6tables NAT is a separate kernel feature (CONFIG_IP6_NF_NAT plus the
# REDIRECT target) that not every kernel has, so it is probed: insert a
# harmless rule for a destination nobody uses, delete it again. The answer
# is kept per process and in a state file for the WebUI.
#
# Whether the redirect is WANTED is not decided here: apply_ip_mode writes
# it to $IP6_REDIRECT_FILE, and every process reads that file. A long-lived
# watchdog with settings loaded minutes ago must never undo a mode switch
# made from the WebUI a second ago.
# -----------------------------------------------------------------
IP6_REDIRECT_FILE="/data/adb/dnscrypt-proxy-state/ip6_redirect"
IP6_NAT_FILE="/data/adb/dnscrypt-proxy-state/ip6_nat"

have_ip6_nat() {
  [ -n "$IP6_NAT_OK" ] && return "$IP6_NAT_OK"
  if ip6tables -t nat -I OUTPUT 1 -p udp -d ::2 --dport 53 -j REDIRECT --to-ports 5354 2>/dev/null; then
    ip6tables -t nat -D OUTPUT -p udp -d ::2 --dport 53 -j REDIRECT --to-ports 5354 2>/dev/null
    IP6_NAT_OK=0
    echo 1 > "$IP6_NAT_FILE" 2>/dev/null
  else
    IP6_NAT_OK=1
    echo 0 > "$IP6_NAT_FILE" 2>/dev/null
  fi
  return "$IP6_NAT_OK"
}

ip6_redirect_wanted() {
  _w=0
  [ -f "$IP6_REDIRECT_FILE" ] && read -r _w 2>/dev/null < "$IP6_REDIRECT_FILE"
  [ "$_w" = "1" ]
  _r=$?; unset _w; return $_r
}

rules_install_dns6() {
  ip6tables -t nat -C OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports 5354 2>/dev/null || \
    ip6tables -t nat -I OUTPUT 1 -p tcp --dport 53 -j REDIRECT --to-ports 5354 2>/dev/null
  ip6tables -t nat -C OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 5354 2>/dev/null || \
    ip6tables -t nat -I OUTPUT 1 -p udp --dport 53 -j REDIRECT --to-ports 5354 2>/dev/null
}

rules_remove_dns6() {
  ip6tables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports 5354 2>/dev/null
  ip6tables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 5354 2>/dev/null
}

# -----------------------------------------------------------------
# Remove every rule this module has ever installed, in any version.
# Safe to call repeatedly; each -D is a no-op if the rule is absent.
# -----------------------------------------------------------------
rules_flush_all() {
  # r10 and earlier: appended redirect + the dead DROP rules
  iptables -t nat -D OUTPUT -p tcp --dport 53 -j DNAT --to-destination "$DNS_REDIR" 2>/dev/null
  iptables -t nat -D OUTPUT -p udp --dport 53 -j DNAT --to-destination "$DNS_REDIR" 2>/dev/null
  iptables -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null
  iptables -D OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null
  iptables -D OUTPUT -p udp --dport 443 -j DROP 2>/dev/null

  # r11 rule set
  rules_remove_dns
  rules_remove_quic

  # r15 hotspot chains (defined further down)
  hotspot_teardown
}

# -----------------------------------------------------------------
# Install the DNS redirect + leak guard.
# Inserted in reverse order so the final chain order is:
#   nat OUTPUT:    [bootstrap RETURNs] [udp DNAT] [tcp DNAT] ...
#   filter OUTPUT: [bootstrap ACCEPTs] [udp DROP] [tcp DROP] ...
# -----------------------------------------------------------------
rules_install_dns() {
  # The exemptions (RETURN in nat, ACCEPT in filter) only work ABOVE the
  # rule they exempt from. On a fresh install that falls out of the insert
  # order, but a repair is different: when netd or a VPN takes out only
  # the DNAT or only the DROP, r12 re-inserted it at position 1 - above
  # the exemptions, which then never matched, and the daemon's own
  # bootstrap queries went into the redirect (nat) or were dropped
  # (filter). So whenever a DNAT or DROP had to be (re)inserted, the
  # exemptions are re-seated at the top afterwards. The DNAT and DROP
  # themselves are never taken down for this, so protection has no gap.
  _nat_new=0
  iptables -t nat -C OUTPUT -p tcp --dport 53 -j DNAT --to-destination "$DNS_REDIR" 2>/dev/null || {
    iptables -t nat -I OUTPUT 1 -p tcp --dport 53 -j DNAT --to-destination "$DNS_REDIR" 2>/dev/null; _nat_new=1; }
  iptables -t nat -C OUTPUT -p udp --dport 53 -j DNAT --to-destination "$DNS_REDIR" 2>/dev/null || {
    iptables -t nat -I OUTPUT 1 -p udp --dport 53 -j DNAT --to-destination "$DNS_REDIR" 2>/dev/null; _nat_new=1; }

  if have_owner_match; then
    for _ip in $BOOTSTRAP_IPS; do
      for _pr in tcp udp; do
        if [ "$_nat_new" -eq 1 ]; then
          iptables -t nat -D OUTPUT -p "$_pr" -d "$_ip" --dport 53 -m owner --uid-owner 0 -j RETURN 2>/dev/null
        fi
        iptables -t nat -C OUTPUT -p "$_pr" -d "$_ip" --dport 53 -m owner --uid-owner 0 -j RETURN 2>/dev/null || \
          iptables -t nat -I OUTPUT 1 -p "$_pr" -d "$_ip" --dport 53 -m owner --uid-owner 0 -j RETURN 2>/dev/null
      done
    done
    unset _ip _pr
  fi

  # Leak guard: anything on port 53 that did NOT get redirected and is
  # not going to loopback is, by definition, plaintext DNS escaping the
  # proxy. Drop it. Only installed when the bootstrap exemption above
  # could also be installed - without xt_owner this rule would block the
  # daemon itself if sources were ever re-enabled, and failing open beats
  # bricking DNS.
  if have_owner_match; then
    _flt_new=0
    iptables -C OUTPUT ! -o lo -p tcp --dport 53 -j DROP 2>/dev/null || {
      iptables -I OUTPUT 1 ! -o lo -p tcp --dport 53 -j DROP 2>/dev/null; _flt_new=1; }
    iptables -C OUTPUT ! -o lo -p udp --dport 53 -j DROP 2>/dev/null || {
      iptables -I OUTPUT 1 ! -o lo -p udp --dport 53 -j DROP 2>/dev/null; _flt_new=1; }
    for _ip in $BOOTSTRAP_IPS; do
      for _pr in tcp udp; do
        if [ "$_flt_new" -eq 1 ]; then
          iptables -D OUTPUT ! -o lo -p "$_pr" -d "$_ip" --dport 53 -m owner --uid-owner 0 -j ACCEPT 2>/dev/null
        fi
        iptables -C OUTPUT ! -o lo -p "$_pr" -d "$_ip" --dport 53 -m owner --uid-owner 0 -j ACCEPT 2>/dev/null || \
          iptables -I OUTPUT 1 ! -o lo -p "$_pr" -d "$_ip" --dport 53 -m owner --uid-owner 0 -j ACCEPT 2>/dev/null
      done
    done
    unset _ip _pr _flt_new
  fi
  unset _nat_new

  # IPv6 DNS never goes through this proxy. If the IPv6 killswitch is off
  # or has been lifted, port-53 over IPv6 would be a wide open side door.
  ip6tables -C OUTPUT ! -o lo -p udp --dport 53 -j DROP 2>/dev/null || \
    ip6tables -I OUTPUT 1 ! -o lo -p udp --dport 53 -j DROP 2>/dev/null
  ip6tables -C OUTPUT ! -o lo -p tcp --dport 53 -j DROP 2>/dev/null || \
    ip6tables -I OUTPUT 1 ! -o lo -p tcp --dport 53 -j DROP 2>/dev/null

  # IPv6 DNS goes through the proxy too, when the IP mode allows IPv6 and
  # the kernel can NAT it. Otherwise the v6 leak guard above drops it.
  if ip6_redirect_wanted && have_ip6_nat; then
    rules_install_dns6
  else
    rules_remove_dns6
  fi
}

# -----------------------------------------------------------------
# Tear the DNS redirect and its guard back down.
# This is what the failsafe calls: with the daemon dead, leaving the
# redirect in place means every DNS query is NATed to a port nobody is
# listening on - which looks exactly like "no internet" and does not
# heal on reboot.
# -----------------------------------------------------------------
rules_remove_dns() {
  iptables -t nat -D OUTPUT -p tcp --dport 53 -j DNAT --to-destination "$DNS_REDIR" 2>/dev/null
  iptables -t nat -D OUTPUT -p udp --dport 53 -j DNAT --to-destination "$DNS_REDIR" 2>/dev/null
  iptables -D OUTPUT ! -o lo -p tcp --dport 53 -j DROP 2>/dev/null
  iptables -D OUTPUT ! -o lo -p udp --dport 53 -j DROP 2>/dev/null
  ip6tables -D OUTPUT ! -o lo -p udp --dport 53 -j DROP 2>/dev/null
  ip6tables -D OUTPUT ! -o lo -p tcp --dport 53 -j DROP 2>/dev/null
  for _ip in $BOOTSTRAP_IPS; do
    iptables -t nat -D OUTPUT -p tcp -d "$_ip" --dport 53 -m owner --uid-owner 0 -j RETURN 2>/dev/null
    iptables -t nat -D OUTPUT -p udp -d "$_ip" --dport 53 -m owner --uid-owner 0 -j RETURN 2>/dev/null
    iptables -D OUTPUT ! -o lo -p tcp -d "$_ip" --dport 53 -m owner --uid-owner 0 -j ACCEPT 2>/dev/null
    iptables -D OUTPUT ! -o lo -p udp -d "$_ip" --dport 53 -m owner --uid-owner 0 -j ACCEPT 2>/dev/null
  done
  unset _ip
  rules_remove_dns6
}

# -----------------------------------------------------------------
# Is the redirect currently in place? Used by the watchdog to notice
# that netd has flushed our chain and put it straight back.
# -----------------------------------------------------------------
rules_dns_present() {
  # Check one sentinel from EACH table. netd can rebuild filter without
  # touching nat and vice versa - a VPN going up or down does exactly
  # that - so testing only the redirect would leave the leak guard
  # missing indefinitely without anyone noticing.
  iptables -t nat -C OUTPUT -p udp --dport 53 -j DNAT --to-destination "$DNS_REDIR" 2>/dev/null || return 1
  if have_owner_match; then
    iptables -C OUTPUT ! -o lo -p udp --dport 53 -j DROP 2>/dev/null || return 1
  fi
  ip6tables -C OUTPUT ! -o lo -p udp --dport 53 -j DROP 2>/dev/null || return 1
  if ip6_redirect_wanted && have_ip6_nat; then
    ip6tables -t nat -C OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 5354 2>/dev/null || return 1
  fi
  return 0
}

# Is ANY part of the redirect still in place? While protection is paused
# everything has to go, and "not all present" (above) is not "none
# present": with only the DROP gone, r12 left the DNAT in place for the
# whole pause and DNS stayed redirected.
rules_dns_any_present() {
  iptables -t nat -C OUTPUT -p udp --dport 53 -j DNAT --to-destination "$DNS_REDIR" 2>/dev/null && return 0
  iptables -t nat -C OUTPUT -p tcp --dport 53 -j DNAT --to-destination "$DNS_REDIR" 2>/dev/null && return 0
  iptables -C OUTPUT ! -o lo -p udp --dport 53 -j DROP 2>/dev/null && return 0
  iptables -C OUTPUT ! -o lo -p tcp --dport 53 -j DROP 2>/dev/null && return 0
  ip6tables -C OUTPUT ! -o lo -p udp --dport 53 -j DROP 2>/dev/null && return 0
  ip6tables -t nat -C OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 5354 2>/dev/null && return 0
  return 1
}

# -----------------------------------------------------------------
# QUIC (UDP/443). r10 only ever blocked it over IPv4, so the moment the
# IPv6 killswitch was lifted, Chrome could go right back to QUIC+DoH
# over v6. Both families now.
# -----------------------------------------------------------------
rules_install_quic() {
  iptables -C OUTPUT -p udp --dport 443 -j DROP 2>/dev/null || \
    iptables -I OUTPUT 1 -p udp --dport 443 -j DROP 2>/dev/null
  ip6tables -C OUTPUT -p udp --dport 443 -j DROP 2>/dev/null || \
    ip6tables -I OUTPUT 1 -p udp --dport 443 -j DROP 2>/dev/null
}

rules_remove_quic() {
  iptables -D OUTPUT -p udp --dport 443 -j DROP 2>/dev/null
  ip6tables -D OUTPUT -p udp --dport 443 -j DROP 2>/dev/null
}

# -----------------------------------------------------------------
# Hotspot / tethering clients (r15)
#
# What was measured on the phone before writing this (Poco F6 Pro,
# hotspot on wlan2, laptop as client):
#   - A client that uses the DNS server it got from DHCP (the phone)
#     is ALREADY protected: Android's tethering DNS forwarder (dnsmasq,
#     uid dns_tether) sends the query on from the phone itself, through
#     nat OUTPUT, into our DNAT. A blocked name came back blocked.
#   - A client with a hard-coded server (8.8.8.8) goes through FORWARD
#     and bypasses everything.
#
# So, per tethered interface:
#   HOTSPOT_DNS=1
#     nat PREROUTING  -> DNSC_HS_PRE: any :53 from a client (IPv4) is
#       REDIRECTed to :53 on the interface's own address, i.e. to the
#       phone's dnsmasq, and from there takes the proven path above.
#       The dnscrypt-proxy listener stays on 127.0.0.1 only.
#     filter FORWARD  -> DNSC_HS_FWD: :53 that still reaches FORWARD is
#       rejected - over IPv4 only if the redirect were missing, over
#       IPv6 always (no IPv6 NAT dependency: clients fall back to IPv4).
#   HOTSPOT_DOT=1
#     filter FORWARD  -> DNSC_HS_FWD: :853 (DoT, DoQ) rejected on both
#       families. Private DNS "Automatic" on a client falls back to plain
#       DNS (and so to us); "Private DNS provider hostname" (strict) does
#       not fall back and has no DNS - that is what the separate switch
#       is for.
#
# Tethered interfaces are the downstream side of netd's own
# tetherctrl_FORWARD rules, so they follow whatever Android tethers
# (wlan2, softap0, rndis0, bt-pan, ...) and disappear when it stops.
#
# Settings are read from the file on every call, not from variables: the
# long-lived watchdog must never put back a switch the user has just
# turned off in the WebUI.
# -----------------------------------------------------------------
HS_PRE="DNSC_HS_PRE"
HS_FWD="DNSC_HS_FWD"
HS_STATE_FILE="/data/adb/dnscrypt-proxy-state/hotspot_applied"
HS_LOCK="/data/adb/dnscrypt-proxy-state/hotspot.lock"

# The watchdog and a WebUI switch can rebuild the chains at the same
# moment; a flush from one in the middle of the other's refill showed up as
# "repairing" (and could double rules until the next tick). One at a time.
# A lock older than ~3 s belongs to something that died: taken over.
_hs_lock() {
  _lw=0
  while ! mkdir "$HS_LOCK" 2>/dev/null; do
    _lw=$((_lw + 1))
    if [ "$_lw" -ge 30 ]; then
      rm -rf "$HS_LOCK"; mkdir "$HS_LOCK" 2>/dev/null; break
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done
  unset _lw
}
_hs_unlock() { rmdir "$HS_LOCK" 2>/dev/null; }

_hs_conf() { # <KEY> -> 0|1 (default 0)
  _hv=$(sed -n "s/^$1=\([01]\).*/\1/p" "$CONF" 2>/dev/null | tail -n 1)
  echo "${_hv:-0}"
  unset _hv
}

# Downstream interfaces of the running tethering, one per line.
# netd writes, per downstream/upstream pair:
#   -A tetherctrl_FORWARD -i rmnet_data1 -o wlan2 -m state --state RELATED,ESTABLISHED -g tetherctrl_counters
#   -A tetherctrl_FORWARD -i wlan2 -o rmnet_data1 -m state --state INVALID -j DROP
#   -A tetherctrl_FORWARD -i wlan2 -o rmnet_data1 -g tetherctrl_counters
# The last form (no --state) always has the client side as -i.
hotspot_ifaces() {
  { iptables -S tetherctrl_FORWARD 2>/dev/null; ip6tables -S tetherctrl_FORWARD 2>/dev/null; } |
    sed -n -e '/--state/d' -e '/-[gj] tetherctrl_counters/s/.* -i \([A-Za-z0-9_.-]*\) .*/\1/p' |
    sort -u
}

# The same, space-separated on one line.
hotspot_ifaces_line() {
  _il=""
  for _ix in $(hotspot_ifaces); do _il="$_il${_il:+ }$_ix"; done
  echo "$_il"
  unset _il _ix
}

# Rules in a chain (lines starting with -A).
_hs_count() { # <cmd> <table> <chain>
  "$1" -t "$2" -S "$3" 2>/dev/null | grep -c '^-A '
}

# REJECT, or DROP where the kernel has no REJECT target.
_hs_reject() { # <cmd> <iface> <proto> <port>
  if [ "$3" = "tcp" ]; then
    "$1" -A "$HS_FWD" -i "$2" -p tcp --dport "$4" -j REJECT --reject-with tcp-reset 2>/dev/null || \
      "$1" -A "$HS_FWD" -i "$2" -p tcp --dport "$4" -j DROP 2>/dev/null
  else
    "$1" -A "$HS_FWD" -i "$2" -p udp --dport "$4" -j REJECT 2>/dev/null || \
      "$1" -A "$HS_FWD" -i "$2" -p udp --dport "$4" -j DROP 2>/dev/null
  fi
}

# Own chain + a jump at the top of the parent. Called every tick, so a
# jump netd dropped is back within one tick.
_hs_hook() { # <cmd> <table> <parent> <chain>
  "$1" -t "$2" -N "$4" 2>/dev/null
  "$1" -t "$2" -C "$3" -j "$4" 2>/dev/null || \
    "$1" -t "$2" -I "$3" 1 -j "$4" 2>/dev/null
}

# ip6tables usable at all? (Always on Android; not in every test sandbox,
# and a family that cannot be written must not force a rebuild per tick.)
_hs_fams() {
  if ip6tables -S FORWARD >/dev/null 2>&1; then echo "iptables ip6tables"; else echo iptables; fi
}

_hs_fill() { # <dns 0|1> <dot 0|1> <ifaces...>
  _fd=$1; _ft=$2; shift 2
  iptables -t nat -F "$HS_PRE" 2>/dev/null
  for _fc in $HS_FAMS; do "$_fc" -F "$HS_FWD" 2>/dev/null; done
  for _fi in "$@"; do
    if [ "$_fd" = "1" ]; then
      iptables -t nat -A "$HS_PRE" -i "$_fi" -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null
      iptables -t nat -A "$HS_PRE" -i "$_fi" -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null
      for _fc in $HS_FAMS; do
        _hs_reject "$_fc" "$_fi" udp 53
        _hs_reject "$_fc" "$_fi" tcp 53
      done
    fi
    if [ "$_ft" = "1" ]; then
      for _fc in $HS_FAMS; do
        _hs_reject "$_fc" "$_fi" tcp 853
        _hs_reject "$_fc" "$_fi" udp 853
      done
    fi
  done
  unset _fd _ft _fi _fc
}

# Bring the hotspot rules in line with the settings and the tethering
# that is running right now. Idempotent; the watchdog calls it every tick.
hotspot_sync() {
  _hs_lock
  _hotspot_sync
  _hs_unlock
}

_hotspot_sync() {
  _hd=$(_hs_conf HOTSPOT_DNS)
  _ht=$(_hs_conf HOTSPOT_DOT)
  if is_paused || { [ "$_hd" != "1" ] && [ "$_ht" != "1" ]; }; then
    [ -f "$HS_STATE_FILE" ] && _hotspot_teardown
    unset _hd _ht
    return 0
  fi

  _hi=$(hotspot_ifaces_line)
  _hn=0
  for _x in $_hi; do _hn=$((_hn + 1)); done

  HS_FAMS=$(_hs_fams)
  _hs_hook iptables nat PREROUTING "$HS_PRE"
  for _x in $HS_FAMS; do _hs_hook "$_x" filter FORWARD "$HS_FWD"; done

  # Expected rule counts; a mismatch means the chain is new, was flushed
  # or is stale, and it is rebuilt from scratch.
  _e4n=$((_hn * 2 * _hd))
  _e6f=$((_hn * (2 * _hd + 2 * _ht)))
  _sig="dns=$_hd dot=$_ht if=$_hi"
  _cur=""
  [ -f "$HS_STATE_FILE" ] && read -r _cur 2>/dev/null < "$HS_STATE_FILE"
  if [ "$_cur" != "$_sig" ] || \
     [ "$(_hs_count iptables nat "$HS_PRE")" != "$_e4n" ] || \
     [ "$(_hs_count iptables filter "$HS_FWD")" != "$_e6f" ] || \
     { [ "$HS_FAMS" != "iptables" ] && [ "$(_hs_count ip6tables filter "$HS_FWD")" != "$_e6f" ]; }; then
    # shellcheck disable=SC2086
    _hs_fill "$_hd" "$_ht" $_hi
    echo "$_sig" > "$HS_STATE_FILE" 2>/dev/null
    if [ "$_cur" != "$_sig" ]; then
      if [ -n "$_hi" ]; then
        _what=""
        [ "$_hd" = "1" ] && _what="DNS redirect"
        [ "$_ht" = "1" ] && _what="${_what:+$_what + }DoT block"
        log_info "hotspot: protecting clients on $_hi ($_what)"
      else
        log_info "hotspot: protection armed, no tethering active"
      fi
    fi
  fi
  unset _hd _ht _hi _hn _x _e4n _e6f _sig _cur _what
}

# Remove every hotspot rule. Safe to call when nothing is there.
hotspot_teardown() {
  _hs_lock
  _hotspot_teardown
  _hs_unlock
}

_hotspot_teardown() {
  while iptables -t nat -D PREROUTING -j "$HS_PRE" 2>/dev/null; do :; done
  while iptables -D FORWARD -j "$HS_FWD" 2>/dev/null; do :; done
  while ip6tables -D FORWARD -j "$HS_FWD" 2>/dev/null; do :; done
  iptables -t nat -F "$HS_PRE" 2>/dev/null; iptables -t nat -X "$HS_PRE" 2>/dev/null
  iptables -F "$HS_FWD" 2>/dev/null;        iptables -X "$HS_FWD" 2>/dev/null
  ip6tables -F "$HS_FWD" 2>/dev/null;       ip6tables -X "$HS_FWD" 2>/dev/null
  if [ -f "$HS_STATE_FILE" ]; then
    rm -f "$HS_STATE_FILE"
    log_info "hotspot: client rules removed"
  fi
}

# Devices connected to the tethered interfaces, one per line:
#   <state> <mac> <ip>
# state:
#   connected  - associated right now, from the Wi-Fi driver
#                (iw station dump). This is what Android's own "N devices
#                connected" counts.
#   active / stale - interfaces iw cannot ask (USB, Bluetooth) or phones
#                without iw: from the kernel's neighbour table. It cannot
#                tell "connected but quiet" from "already left" (both are
#                STALE), so it is only the fallback.
# Measured on the phone: dumpsys tethering's client list is the DHCP
# leases - a laptop that had left an hour before (and a hotspot restart
# in between) was still in it. Not used.
# ip: from the neighbour table, IPv4 preferred; "-" when not known yet.
hotspot_clients() {
  _nb="$STATE_DIR/hotspot_neigh.tmp"
  : > "$_nb" 2>/dev/null
  _hif=$(hotspot_ifaces)
  for _ci in $_hif; do
    ip neigh show dev "$_ci" 2>/dev/null >> "$_nb"
  done
  _cl=""
  for _ci in $_hif; do
    _sd=""
    if command -v iw >/dev/null 2>&1 && _sd=$(iw dev "$_ci" station dump 2>/dev/null); then
      # A Wi-Fi interface: the driver's list is the truth, even when empty.
      for _mac in $(printf '%s\n' "$_sd" | sed -n 's/^Station \([0-9a-fA-F:]*\) .*/\1/p'); do
        _cl="$_cl connected=$_mac=$(_hs_ip_of "$_mac")"
      done
    else
      _cl="$_cl $(_hs_neigh_clients "$_ci")"
    fi
  done
  rm -f "$_nb"
  for _e in $_cl; do
    _st=${_e%%=*}; _r=${_e#*=}
    echo "$_st ${_r%%=*} ${_r#*=}"
  done
  unset _nb _hif _ci _sd _mac _cl _e _st _r
}

# IP address of a MAC from the saved neighbour table, IPv4 preferred.
_hs_ip_of() { # <mac>
  _i4=""; _i6=""
  while read -r _a _rest; do
    case " $_rest " in *" $1 "*) : ;; *) continue ;; esac
    case "$_a" in
      *:*) [ -z "$_i6" ] && _i6=$_a ;;
      *) [ -z "$_i4" ] && _i4=$_a ;;
    esac
  done < "$_nb"
  if [ -n "$_i4" ]; then echo "$_i4"; elif [ -n "$_i6" ]; then echo "$_i6"; else echo "-"; fi
  unset _i4 _i6 _a _rest
}

# Fallback: clients of one interface from the neighbour table, printed as
# space-separated <state>=<mac>=<ip> entries, one per MAC.
_hs_neigh_clients() { # <iface>
  _nl=""
  ip neigh show dev "$1" 2>/dev/null > "$_nb.1"
  # Two passes: IPv4 entries first, so a device is listed by its IPv4
  # address; its IPv6 entries can still raise it to "active".
  for _pass in 4 6; do
    # Any number of words: busybox ip puts "used 0/0/0 probes 0" before
    # the state, iproute2 does not.
    while read -r _ip _ws; do
      case "$_ip" in *:*) [ "$_pass" = 6 ] || continue ;; *) [ "$_pass" = 4 ] || continue ;; esac
      _m=""; _s=""
      for _w in $_ws; do
        case "$_w" in
          ??:??:??:??:??:??) _m=$_w ;;
          REACHABLE | DELAY | PROBE | PERMANENT) _s=active ;;
          STALE) _s=stale ;;
        esac
      done
      [ -n "$_m" ] && [ -n "$_s" ] || continue
      case " $_nl " in
        *"=$_m="*)
          [ "$_s" = active ] && _nl=$(echo "$_nl" | sed "s/ stale=$_m=/ active=$_m=/") ;;
        *) _nl="$_nl $_s=$_m=$_ip" ;;
      esac
    done < "$_nb.1"
  done
  rm -f "$_nb.1"
  echo "$_nl"
  unset _nl _pass _ip _ws _w _m _s
}
