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
# Our rules as iptables-save prints them (-m udp/-m tcp is added by it)
_RX_REDIR=$(printf '%s' "$DNS_REDIR" | sed 's/\./\\./g')
P_DNAT_UDP="^-A OUTPUT -p udp( -m udp)? --dport 53 -j DNAT --to-destination $_RX_REDIR\$"
P_DNAT_TCP="^-A OUTPUT -p tcp( -m tcp)? --dport 53 -j DNAT --to-destination $_RX_REDIR\$"
P_GUARD_UDP='^-A OUTPUT ! -o lo -p udp( -m udp)? --dport 53 -j DROP$'
P_GUARD_TCP='^-A OUTPUT ! -o lo -p tcp( -m tcp)? --dport 53 -j DROP$'
P_R6_UDP='^-A OUTPUT -p udp( -m udp)? --dport 53 -j REDIRECT --to-ports 5354$'
P_QUIC='^-A OUTPUT -p udp( -m udp)? --dport 443 -j DROP$'
P_CAPJ_UDP='^-A OUTPUT -p udp( -m udp)? --dport 53 -j DNSC_CAP$'
P_BOOT_NAT='^-A OUTPUT -d 9\.9\.9\.9(/32)? -p udp( -m udp)? --dport 53 -m owner --uid-owner 0 -m mark --mark 0x0/0x10000 -j RETURN$'
unset _RX_REDIR
BOOTSTRAP_IPS="9.9.9.9 149.112.112.112 45.11.45.11"
# 2.1.20-r1: the bootstrap exemption is only for sockets NOT bound to a
# network (fwmark bit 0x10000 clear). Measured on the phone: every app's DNS
# query is sent by netd's DnsResolver, which runs as root - so to xt_owner
# ALL of them are uid 0, and all carry the explicit bit. Without the mark
# check, an app's query went around the proxy whenever the network's own DNS
# server was one of the bootstrap addresses (a router handing out Quad9).
# dnscrypt-proxy (Go) and WG Shield's busybox nslookup never bind their
# sockets to a network, so they keep the exemption.
BOOT_MARK="0x0/0x10000"
OWNER_FLAG_FILE="$STATE_DIR/owner_match_unavailable"

# -----------------------------------------------------------------
# Does this kernel have the xt_owner match? Some stripped GKI builds
# do not. Probe once, cache the answer for the boot.
# -----------------------------------------------------------------
OWNER_OK_FILE="$STATE_DIR/owner_match_ok"
have_owner_match() {
  [ -f "$OWNER_FLAG_FILE" ] && return 1
  [ -n "$OWNER_MATCH_OK" ] && return "$OWNER_MATCH_OK"
  # r17: the positive answer is cached per boot too - the probe writes a
  # rule, and every ctl.sh run used to repeat it.
  [ -f "$OWNER_OK_FILE" ] && { OWNER_MATCH_OK=0; return 0; }
  if iptables -t nat -I OUTPUT 1 -p udp -d 127.0.0.2 --dport 53 \
       -m owner --uid-owner 0 -j RETURN 2>/dev/null; then
    iptables -t nat -D OUTPUT -p udp -d 127.0.0.2 --dport 53 \
       -m owner --uid-owner 0 -j RETURN 2>/dev/null
    OWNER_MATCH_OK=0
    : > "$OWNER_OK_FILE" 2>/dev/null
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
IP6_REDIRECT_FILE="$STATE_DIR/ip6_redirect"
IP6_NAT_FILE="$STATE_DIR/ip6_nat"

have_ip6_nat() {
  [ -n "$IP6_NAT_OK" ] && return "$IP6_NAT_OK"
  # r17: answer cached per boot (the probe writes a rule; the WebUI status
  # used to repeat it on every refresh)
  _nf=""; [ -f "$IP6_NAT_FILE" ] && read -r _nf 2>/dev/null < "$IP6_NAT_FILE"
  case "$_nf" in
    1) IP6_NAT_OK=0; unset _nf; return 0 ;;
    0) IP6_NAT_OK=1; unset _nf; return 1 ;;
  esac
  unset _nf
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
  _r6_new=0
  ip6tables -t nat -C OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports 5354 2>/dev/null || {
    ip6tables -t nat -I OUTPUT 1 -p tcp --dport 53 -j REDIRECT --to-ports 5354 2>/dev/null; _r6_new=1; }
  ip6tables -t nat -C OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 5354 2>/dev/null || {
    ip6tables -t nat -I OUTPUT 1 -p udp --dport 53 -j REDIRECT --to-ports 5354 2>/dev/null; _r6_new=1; }
  have_owner_match && _cap_jumps ip6tables nat "$_r6_new"
  unset _r6_new
}

rules_remove_dns6() {
  ip6tables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports 5354 2>/dev/null
  ip6tables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 5354 2>/dev/null
  _cap_unjump ip6tables nat
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

  # 2.1.20-r1 Wi-Fi login chains
  cap_teardown
}

# -----------------------------------------------------------------
# Install the DNS redirect + leak guard.
# Inserted in reverse order so the final chain order is:
#   nat OUTPUT:    [bootstrap RETURNs] [udp DNAT] [tcp DNAT] ...
#   filter OUTPUT: [bootstrap ACCEPTs] [udp DROP] [tcp DROP] ...
# -----------------------------------------------------------------
rules_install_dns() {
  ipt_snap_stale
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
        # 2.1.20 and older: the same rule without the mark check
        iptables -t nat -D OUTPUT -p "$_pr" -d "$_ip" --dport 53 -m owner --uid-owner 0 -j RETURN 2>/dev/null
        if [ "$_nat_new" -eq 1 ]; then
          iptables -t nat -D OUTPUT -p "$_pr" -d "$_ip" --dport 53 -m owner --uid-owner 0 -m mark --mark "$BOOT_MARK" -j RETURN 2>/dev/null
        fi
        iptables -t nat -C OUTPUT -p "$_pr" -d "$_ip" --dport 53 -m owner --uid-owner 0 -m mark --mark "$BOOT_MARK" -j RETURN 2>/dev/null || \
          iptables -t nat -I OUTPUT 1 -p "$_pr" -d "$_ip" --dport 53 -m owner --uid-owner 0 -m mark --mark "$BOOT_MARK" -j RETURN 2>/dev/null
      done
    done
    unset _ip _pr
    # Wi-Fi login (captive portal) exception, above the DNAT too
    _cap_jumps iptables nat "$_nat_new"
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
        iptables -D OUTPUT ! -o lo -p "$_pr" -d "$_ip" --dport 53 -m owner --uid-owner 0 -j ACCEPT 2>/dev/null
        if [ "$_flt_new" -eq 1 ]; then
          iptables -D OUTPUT ! -o lo -p "$_pr" -d "$_ip" --dport 53 -m owner --uid-owner 0 -m mark --mark "$BOOT_MARK" -j ACCEPT 2>/dev/null
        fi
        iptables -C OUTPUT ! -o lo -p "$_pr" -d "$_ip" --dport 53 -m owner --uid-owner 0 -m mark --mark "$BOOT_MARK" -j ACCEPT 2>/dev/null || \
          iptables -I OUTPUT 1 ! -o lo -p "$_pr" -d "$_ip" --dport 53 -m owner --uid-owner 0 -m mark --mark "$BOOT_MARK" -j ACCEPT 2>/dev/null
      done
    done
    _cap_jumps iptables filter "$_flt_new"
    unset _ip _pr _flt_new
  fi
  unset _nat_new

  # IPv6 DNS never goes through this proxy. If the IPv6 killswitch is off
  # or has been lifted, port-53 over IPv6 would be a wide open side door.
  _g6_new=0
  ip6tables -C OUTPUT ! -o lo -p udp --dport 53 -j DROP 2>/dev/null || {
    ip6tables -I OUTPUT 1 ! -o lo -p udp --dport 53 -j DROP 2>/dev/null; _g6_new=1; }
  ip6tables -C OUTPUT ! -o lo -p tcp --dport 53 -j DROP 2>/dev/null || {
    ip6tables -I OUTPUT 1 ! -o lo -p tcp --dport 53 -j DROP 2>/dev/null; _g6_new=1; }
  have_owner_match && _cap_jumps ip6tables filter "$_g6_new"
  unset _g6_new

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
  ipt_snap_stale
  iptables -t nat -D OUTPUT -p tcp --dport 53 -j DNAT --to-destination "$DNS_REDIR" 2>/dev/null
  iptables -t nat -D OUTPUT -p udp --dport 53 -j DNAT --to-destination "$DNS_REDIR" 2>/dev/null
  iptables -D OUTPUT ! -o lo -p tcp --dport 53 -j DROP 2>/dev/null
  iptables -D OUTPUT ! -o lo -p udp --dport 53 -j DROP 2>/dev/null
  ip6tables -D OUTPUT ! -o lo -p udp --dport 53 -j DROP 2>/dev/null
  ip6tables -D OUTPUT ! -o lo -p tcp --dport 53 -j DROP 2>/dev/null
  for _ip in $BOOTSTRAP_IPS; do
    for _pr in tcp udp; do
      iptables -t nat -D OUTPUT -p "$_pr" -d "$_ip" --dport 53 -m owner --uid-owner 0 -m mark --mark "$BOOT_MARK" -j RETURN 2>/dev/null
      iptables -D OUTPUT ! -o lo -p "$_pr" -d "$_ip" --dport 53 -m owner --uid-owner 0 -m mark --mark "$BOOT_MARK" -j ACCEPT 2>/dev/null
      # 2.1.20 and older
      iptables -t nat -D OUTPUT -p "$_pr" -d "$_ip" --dport 53 -m owner --uid-owner 0 -j RETURN 2>/dev/null
      iptables -D OUTPUT ! -o lo -p "$_pr" -d "$_ip" --dport 53 -m owner --uid-owner 0 -j ACCEPT 2>/dev/null
    done
  done
  unset _ip _pr
  _cap_unjump iptables nat
  _cap_unjump iptables filter
  _cap_unjump ip6tables filter
  cap_routes_clear
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
  # missing indefinitely without anyone noticing. Read from the lock-free
  # snapshot (r17).
  ipt_snap
  sn_has "$S4N" "$P_DNAT_UDP" || return 1
  if have_owner_match; then
    sn_has "$S4F" "$P_GUARD_UDP" || return 1
    # 2.1.20-r1: Wi-Fi login exception and the marked bootstrap rule
    # (an update from 2.1.20 reinstalls once and drops the old form)
    sn_has "$S4N" "$P_CAPJ_UDP" || return 1
    sn_has "$S4F" "$P_CAPJ_UDP" || return 1
    sn_has "$S6F" "$P_CAPJ_UDP" || return 1
    sn_has "$S4N" "$P_BOOT_NAT" || return 1
  fi
  sn_has "$S6F" "$P_GUARD_UDP" || return 1
  if ip6_redirect_wanted && have_ip6_nat; then
    sn_has "$S6N" "$P_R6_UDP" || return 1
    have_owner_match && { sn_has "$S6N" "$P_CAPJ_UDP" || return 1; }
  fi
  return 0
}

# Is ANY part of the redirect still in place? While protection is paused
# everything has to go, and "not all present" (above) is not "none
# present": with only the DROP gone, r12 left the DNAT in place for the
# whole pause and DNS stayed redirected.
rules_dns_any_present() {
  ipt_snap
  sn_has "$S4N" "$P_DNAT_UDP" && return 0
  sn_has "$S4N" "$P_DNAT_TCP" && return 0
  sn_has "$S4F" "$P_GUARD_UDP" && return 0
  sn_has "$S4F" "$P_GUARD_TCP" && return 0
  sn_has "$S6F" "$P_GUARD_UDP" && return 0
  sn_has "$S6N" "$P_R6_UDP" && return 0
  return 1
}

# -----------------------------------------------------------------
# QUIC (UDP/443). r10 only ever blocked it over IPv4, so the moment the
# IPv6 killswitch was lifted, Chrome could go right back to QUIC+DoH
# over v6. Both families now.
# -----------------------------------------------------------------
rules_install_quic() {
  # Called every tick: checked on the snapshot, written only when missing
  ipt_snap
  if ! sn_has "$S4F" "$P_QUIC"; then
    iptables -I OUTPUT 1 -p udp --dport 443 -j DROP 2>/dev/null; ipt_snap_stale
  fi
  if ! sn_has "$S6F" "$P_QUIC"; then
    ip6tables -I OUTPUT 1 -p udp --dport 443 -j DROP 2>/dev/null; ipt_snap_stale
  fi
}

rules_remove_quic() {
  ipt_snap
  sn_has "$S4F" "$P_QUIC" && { iptables -D OUTPUT -p udp --dport 443 -j DROP 2>/dev/null; ipt_snap_stale; }
  sn_has "$S6F" "$P_QUIC" && { ip6tables -D OUTPUT -p udp --dport 443 -j DROP 2>/dev/null; ipt_snap_stale; }
  return 0
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
HS_STATE_FILE="$STATE_DIR/hotspot_applied"
HS_LOCK="$STATE_DIR/hotspot.lock"

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
  ipt_snap
  printf '%s\n%s\n' "$S4F" "$S6F" |
    sed -n -e '/^-A tetherctrl_FORWARD /!d' -e '/--state/d' -e '/-[gj] tetherctrl_counters/s/.* -i \([A-Za-z0-9_.-]*\) .*/\1/p' |
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
# The snapshot dump for <cmd> <table>
_hs_dump() {
  case "$1:$2" in
    iptables:filter) printf '%s\n' "$S4F" ;;
    iptables:nat) printf '%s\n' "$S4N" ;;
    ip6tables:filter) printf '%s\n' "$S6F" ;;
    ip6tables:nat) printf '%s\n' "$S6N" ;;
  esac
}

_hs_count() { # <cmd> <table> <chain>
  ipt_snap
  sn_count "$(_hs_dump "$1" "$2")" "$3"
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
  ipt_snap
  _hk_s=$(_hs_dump "$1" "$2")
  if ! sn_chain "$_hk_s" "$4"; then
    "$1" -t "$2" -N "$4" 2>/dev/null; ipt_snap_stale
  fi
  # Jumps counted on the snapshot (no -C: a check that fails because the
  # lock is held would read as "missing" and insert a second jump).
  _hk_n=$(sn_jumps "$_hk_s" "$3" "$4")
  if [ "$_hk_n" = "0" ]; then
    "$1" -t "$2" -I "$3" 1 -j "$4" 2>/dev/null; ipt_snap_stale
  elif [ "$_hk_n" -gt 1 ] 2>/dev/null; then
    # r15 could jump twice (lock race). Remove all, put one back on top.
    while "$1" -t "$2" -D "$3" -j "$4" 2>/dev/null; do :; done
    "$1" -t "$2" -I "$3" 1 -j "$4" 2>/dev/null; ipt_snap_stale
    log_warn "hotspot: removed $((_hk_n - 1)) duplicate $4 jump(s) in $1 $2 $3"
  fi
  unset _hk_s _hk_n
}

# ip6tables usable at all? (Always on Android; not in every test sandbox,
# and a family that cannot be written must not force a rebuild per tick.)
_hs_fams() {
  ipt_snap
  if [ "$S6OK" = 1 ]; then echo "iptables ip6tables"; else echo iptables; fi
}

_hs_fill() { # <dns 0|1> <dot 0|1> <ifaces...>
  _fd=$1; _ft=$2; shift 2
  ipt_snap_stale
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

  ipt_snap                     # in this shell: the $(...) below reuse it
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
  ipt_snap                     # again after a hook may have written
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

# -----------------------------------------------------------------
# Wi-Fi login pages (captive portals) - 2.1.20-r1
#
# On a hotel / airport Wi-Fi nothing reaches the internet until you log
# in, so this proxy cannot resolve anything there - and Android cannot even
# find the login page: its network check and the login app resolve names
# through us too. Only the network's own DNS server works before the login.
#
# What was measured on the phone: every DNS query of every app is sent by
# netd's DnsResolver (root), with the network's netId in the low 16 bits
# of the socket mark and the "explicitly bound" bit 0x10000 set. xt_owner
# sees uid 0 for all of them, so the login app cannot be told apart by
# uid here. It CAN be told apart by the network the query is for.
#
# So: for every Wi-Fi / Ethernet network Android has NOT validated yet
# (still checking, or waiting for a login), netd's queries FOR THAT
# NETWORK skip the redirect and go to the network's own DNS server:
#   nat    OUTPUT :53 -> DNSC_CAP: -m owner --uid-owner 0
#                                  -m mark --mark <0x10000+netId>/0x1ffff -j ACCEPT
#                                  (ACCEPT in nat = no DNAT for it)
#   filter OUTPUT :53 -> DNSC_CAP: the same, above the leak guard
# Once Android has validated the network (logged in), the rules go.
#
# With WG Shield: its routing sends the queries of Android's check (uid
# 1073) and of the login app out on the Wi-Fi, and everything else into
# the tunnel, which is dead until the login - so only those two reach the
# hotel's DNS (the kernel routes by the app's uid, which netd stamps on the
# socket; xt_owner cannot see that). Without WG Shield every app's query
# for that network uses the hotel's DNS until Android has validated it.
#
# IPv6: only in the IP modes that allow it (in "IPv4 only" the phone has no
# IPv6 and Android asks the IPv4 server).
# -----------------------------------------------------------------
CAP_CHAIN="DNSC_CAP"
CAP_FILE="$STATE_DIR/captive"   # 1 signature  2 time of the last dumpsys  3 list
CAP_RECHECK=60                  # dumpsys at least this often (validation can be lost)
CAP_FAST=40                     # seconds of 2 s checks after a network change

# _cap_jumps <iptables|ip6tables> <nat|filter> <reseat 0|1>
# The jumps must sit above the DNAT / REDIRECT / leak guard. When one of
# those was just (re)inserted at the top, the jumps are moved back above it.
_cap_jumps() {
  "$1" -t "$2" -N "$CAP_CHAIN" 2>/dev/null
  for _cj in tcp udp; do
    if [ "$3" = 1 ]; then
      while "$1" -t "$2" -D OUTPUT -p "$_cj" --dport 53 -j "$CAP_CHAIN" 2>/dev/null; do :; done
    fi
    "$1" -t "$2" -C OUTPUT -p "$_cj" --dport 53 -j "$CAP_CHAIN" 2>/dev/null || \
      "$1" -t "$2" -I OUTPUT 1 -p "$_cj" --dport 53 -j "$CAP_CHAIN" 2>/dev/null
  done
  unset _cj
}

_cap_unjump() { # <iptables|ip6tables> <nat|filter>
  for _cj in tcp udp; do
    while "$1" -t "$2" -D OUTPUT -p "$_cj" --dport 53 -j "$CAP_CHAIN" 2>/dev/null; do :; done
  done
  unset _cj
}

cap_teardown() {
  _cap_unjump iptables nat;  _cap_unjump iptables filter
  _cap_unjump ip6tables nat; _cap_unjump ip6tables filter
  for _ct in "iptables nat" "iptables filter" "ip6tables nat" "ip6tables filter"; do
    set -- $_ct
    "$1" -t "$2" -F "$CAP_CHAIN" 2>/dev/null; "$1" -t "$2" -X "$CAP_CHAIN" 2>/dev/null
  done
  rm -f "$CAP_FILE" 2>/dev/null
  cap_routes_clear
  ipt_snap_stale
  unset _ct
}

# dumpsys connectivity lines -> "netId:iface:login|checking" for every
# Wi-Fi / Ethernet network with INTERNET, not restricted, not VALIDATED.
# "login" = Android found a login page (CAPTIVE_PORTAL), "checking" = not
# decided yet (or no internet there at all).
cap_parse() {
  while IFS= read -r _l; do
    case "$_l" in *"NetworkAgentInfo{network{"*) ;; *) continue ;; esac
    case "$_l" in *"Transports: "*) ;; *) continue ;; esac
    case "$_l" in *"Capabilities: "*) ;; *) continue ;; esac
    _tr=${_l#*Transports: }; _tr=${_tr%% *}
    case "|$_tr|" in *"|WIFI|"* | *"|ETHERNET|"*) ;; *) continue ;; esac
    _caps=${_l#*Capabilities: }; _caps=${_caps%% *}
    case "&$_caps&" in *"&INTERNET&"*) ;; *) continue ;; esac
    case "&$_caps&" in *"&NOT_RESTRICTED&"*) ;; *) continue ;; esac
    case "&$_caps&" in *"&VALIDATED&"*) continue ;; esac
    _nid=${_l#*NetworkAgentInfo\{network\{}; _nid=${_nid%%\}*}
    case "$_nid" in '' | *[!0-9]*) continue ;; esac
    [ "$_nid" -gt 0 ] && [ "$_nid" -lt 65536 ] || continue
    _if=""
    case "$_l" in *"InterfaceName: "*) _if=${_l#*InterfaceName: }; _if=${_if%% *} ;; esac
    case "$_if" in '' | *[!A-Za-z0-9_.@-]*) _if="?" ;; esac
    _k=checking
    case "&$_caps&" in *"&CAPTIVE_PORTAL&"*) _k=login ;; esac
    # the network's DNS servers: "DnsAddresses: [ /192.168.1.1,/fd00::1 ]"
    _dl=""
    case "$_l" in *"DnsAddresses: ["*)
      _d=${_l#*DnsAddresses: \[}; _d=${_d%%\]*}
      _ifs=$IFS; IFS=', '
      for _a in $_d; do
        _a=${_a#/}; _a=${_a%%%*}
        case "$_a" in
          '' | *[!0-9a-fA-F.:]*) continue ;;
          [fF][eE]80:*) continue ;;              # link-local: never used for DNS here
          *:*) ;;                                # IPv6
          *.*.*.*) case "$_a" in *[!0-9.]*) continue ;; esac ;;
          *) continue ;;
        esac
        _dl="$_dl${_dl:+,}$_a"
      done
      IFS=$_ifs ;;
    esac
    echo "$_nid:$_if:$_k;$_dl"
  done
  unset _l _tr _caps _nid _if _k _d _dl _a _ifs
}

cap_detect() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 10 dumpsys connectivity 2>/dev/null
  else
    dumpsys connectivity 2>/dev/null
  fi | grep '^ *NetworkAgentInfo{' | cap_parse | sort -u
}

# Cheap change detector, read every tick: netd adds an "explicit" rule
# (fwmark 0x1<netId>/0x1ffff) for every network it creates - a reconnect to
# the same Wi-Fi gets a new netId, so this changes too.
_cap_sig() {
  ip rule 2>/dev/null | sed -n 's/.*fwmark \(0x[0-9a-fA-F]*\)\/0x1ffff.*/\1/p' | sort -u | awk '{ printf "%s ", $0 }'
}

# The cached list ("netId:iface:kind ..."), empty when none. In the file
# every entry also carries ";<its DNS servers>".
cap_list() {
  [ -f "$CAP_FILE" ] && sed -n 3p "$CAP_FILE" 2>/dev/null | sed 's/;[^ ]*//g'
}

# Marks in the chain of one dump, sorted, one line.
_cap_have() { # <dump>
  printf '%s\n' "$1" | sed -n "s/^-A $CAP_CHAIN .*--mark \(0x[0-9a-f]*\)\/0x1ffff .*/\1/p" | sort | awk '{ printf "%s%s", (NR > 1 ? " " : ""), $0 }'
}

# _cap_fill <iptables|ip6tables> <nat|filter> <dump> <sorted marks>
_cap_fill() {
  _cf_n=0; for _cf_m in $4; do _cf_n=$((_cf_n + 1)); done
  sn_chain "$3" "$CAP_CHAIN" || "$1" -t "$2" -N "$CAP_CHAIN" 2>/dev/null
  if [ "$(_cap_have "$3")" != "$4" ] || [ "$(sn_count "$3" "$CAP_CHAIN")" != "$_cf_n" ]; then
    "$1" -t "$2" -F "$CAP_CHAIN" 2>/dev/null
    for _cf_m in $4; do
      "$1" -t "$2" -A "$CAP_CHAIN" -m owner --uid-owner 0 -m mark --mark "$_cf_m/0x1ffff" -j ACCEPT 2>/dev/null
    done
    _cf_changed=1
  fi
  unset _cf_n _cf_m
}

# ---- Only Android's check and the login page ---------------------------
# The ACCEPT above lets netd's query go to the network's own DNS server.
# Which app the query is for, only the routing can see (netd stamps the
# app's uid on the socket; xt_owner sees root). Without more, WG Shield's
# "LAN stays local" rule (5012) - or plain netd routing without WG Shield -
# would carry EVERY app's query for that network to a DNS server on the
# LAN, and the hotel would see the names. So, while a network is open,
# every uid EXCEPT Android's network check (1073) and the captive portal
# login app gets "unreachable" towards that network's DNS servers:
#   pref 4950  iif lo fwmark <netId>/0xffff to <server> uidrange <a>-<b> unreachable
# (one rule per uid range around the exempt uids). The route lookup
# happens before nat, so an app's query to that server fails at once -
# nothing works on such a network before the login anyway. Before the
# WG Shield rules (5000+); Android's own rules start at 10000.
CAP_PREF=4950
CAP_RULES_FILE="$STATE_DIR/captive_rules"
CAP_UIDS_FILE="$STATE_DIR/captive_uids"
CAP_NETSTACK_UID=1073
CAP_IP="${DNSC_IP:-/system/bin/ip}"
[ -x "$CAP_IP" ] || CAP_IP=ip
CAP_PM="${DNSC_PM:-pm}"

# Android's network check + the login app(s), sorted. The package manager
# answers only after boot; until then NetworkStack alone, asked again later.
cap_uids() {
  if [ ! -f "$CAP_UIDS_FILE" ] && [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
    _cu_p=$("$CAP_PM" list packages -U 2>/dev/null)
    if [ -n "$_cu_p" ]; then
      _cu_u=$(printf '%s\n' "$_cu_p" | grep -i captiveportal | sed -n 's/.*uid:\([0-9][0-9]*\).*/\1/p')
      printf '%s\n' $CAP_NETSTACK_UID $_cu_u | sort -un | awk '{ printf "%s%s", (NR > 1 ? " " : ""), $0 } END { print "" }' \
        > "$CAP_UIDS_FILE.tmp" 2>/dev/null && mv -f "$CAP_UIDS_FILE.tmp" "$CAP_UIDS_FILE"
    fi
  fi
  if [ -s "$CAP_UIDS_FILE" ]; then cat "$CAP_UIDS_FILE"; else echo "$CAP_NETSTACK_UID"; fi
  unset _cu_p _cu_u
}

# _cap_routes_want <entries> <v6 0|1>: the rule lines (ip arguments)
_cap_routes_want() {
  _rw_lo=0; _rw_r=""
  for _rw_u in $(cap_uids); do
    [ "$_rw_u" -gt "$_rw_lo" ] && _rw_r="$_rw_r $_rw_lo-$((_rw_u - 1))"
    _rw_lo=$((_rw_u + 1))
  done
  _rw_r="$_rw_r $_rw_lo-4294967294"
  for _rw_e in $1; do
    _rw_n=${_rw_e%%:*}; _rw_s=${_rw_e#*;}
    [ "$_rw_s" = "$_rw_e" ] && continue
    _rw_m=$(printf '0x%x' "$_rw_n")
    _ifs=$IFS; IFS=','
    for _rw_a in $_rw_s; do
      IFS=$_ifs
      case "$_rw_a" in
        *:*) [ "$2" = 1 ] || continue; _rw_f=-6 ;;
        *) _rw_f=-4 ;;
      esac
      for _rw_x in $_rw_r; do
        echo "$_rw_f rule add pref $CAP_PREF iif lo fwmark $_rw_m/0xffff to $_rw_a uidrange $_rw_x unreachable"
      done
      IFS=','
    done
    IFS=$_ifs
  done
  unset _rw_lo _rw_r _rw_u _rw_e _rw_n _rw_s _rw_m _rw_a _rw_f _rw_x _ifs
}

_cap_rule_count() { # <-4|-6>
  "$CAP_IP" "$1" rule 2>/dev/null | grep -c "^$CAP_PREF:"
}

# _cap_routes_apply <wanted lines>: add the new ones first, then delete the
# ones no longer wanted (never a moment without them). A count that does not
# match (someone flushed rules, a leftover) -> all of ours re-done.
_cap_routes_apply() {
  _ra_old=""; [ -f "$CAP_RULES_FILE" ] && _ra_old=$(cat "$CAP_RULES_FILE" 2>/dev/null)
  _ra_w4=$(printf '%s\n' "$1" | grep -c '^-4 ')
  _ra_w6=$(printf '%s\n' "$1" | grep -c '^-6 ')
  if [ "$1" = "$_ra_old" ] && [ "$(_cap_rule_count -4)" = "$_ra_w4" ] && \
     { [ "$_ra_w6" = 0 ] || [ "$(_cap_rule_count -6)" = "$_ra_w6" ]; }; then
    unset _ra_old _ra_w4 _ra_w6; return 0
  fi
  if [ "$1" != "$_ra_old" ]; then
    printf '%s\n' "$1" | while IFS= read -r _ra_l; do
      [ -n "$_ra_l" ] || continue
      printf '%s\n' "$_ra_old" | grep -qxF -- "$_ra_l" && continue
      # shellcheck disable=SC2086
      "$CAP_IP" $_ra_l 2>/dev/null
    done
    printf '%s\n' "$_ra_old" | while IFS= read -r _ra_l; do
      [ -n "$_ra_l" ] || continue
      printf '%s\n' "$1" | grep -qxF -- "$_ra_l" && continue
      # shellcheck disable=SC2046,SC2086
      "$CAP_IP" $(printf '%s' "$_ra_l" | sed 's/ rule add / rule del /') 2>/dev/null
    done
  fi
  if [ "$(_cap_rule_count -4)" != "$_ra_w4" ] || { [ "$_ra_w6" != 0 ] && [ "$(_cap_rule_count -6)" != "$_ra_w6" ]; }; then
    _cap_routes_flush
    printf '%s\n' "$1" | while IFS= read -r _ra_l; do
      # shellcheck disable=SC2086
      [ -n "$_ra_l" ] && "$CAP_IP" $_ra_l 2>/dev/null
    done
  fi
  if [ -n "$1" ]; then
    printf '%s\n' "$1" > "$CAP_RULES_FILE" 2>/dev/null
  else
    rm -f "$CAP_RULES_FILE" 2>/dev/null
  fi
  unset _ra_old _ra_w4 _ra_w6 _ra_l
}

_cap_routes_flush() {
  _rf=0
  while "$CAP_IP" -4 rule del pref "$CAP_PREF" 2>/dev/null && [ "$_rf" -lt 200 ]; do _rf=$((_rf + 1)); done
  _rf=0
  while "$CAP_IP" -6 rule del pref "$CAP_PREF" 2>/dev/null && [ "$_rf" -lt 200 ]; do _rf=$((_rf + 1)); done
  unset _rf
}

# Pause, failsafe, uninstall: nothing of ours may stay in the routing
cap_routes_clear() {
  [ -f "$CAP_RULES_FILE" ] || [ "$(_cap_rule_count -4)" != 0 ] || [ "$(_cap_rule_count -6)" != 0 ] || return 0
  _cap_routes_flush
  rm -f "$CAP_RULES_FILE" 2>/dev/null
}

# Every watchdog tick while protection is on. dumpsys only when a network
# came or went, while a network is open (to close it right after the
# login), and every CAP_RECHECK seconds otherwise.
#
# A network that is only "being checked" stays open for CAP_WINDOW seconds
# from the moment it was first seen unvalidated - long enough for Android's
# check to find a login page (then it stays open as "login" until Android
# has validated it). A network Android never validates although it works
# (blocked check servers, "partial connectivity", a LAN without internet)
# goes back to normal after that: the proxy answers every app again.
#
# $CAP_FILE: 1 signature  2 time of the last dumpsys  3 open list (shown)
#            4 every unvalidated network seen  5 first seen "netId=epoch ..."
CAP_FAST_UNTIL=0
CAP_WINDOW=${DNSC_CAP_WINDOW:-90}
cap_sync() {
  have_owner_match || return 0
  ipt_snap
  _cs_sig=$(_cap_sig)
  _cs_now=$(date +%s)
  _cs_osig=""; _cs_ot=0; _cs_old=""; _cs_det=""; _cs_fs=""
  _cs_had=0
  if [ -f "$CAP_FILE" ]; then
    _cs_had=1
    _cs_osig=$(sed -n 1p "$CAP_FILE" 2>/dev/null)
    _cs_ot=$(sed -n 2p "$CAP_FILE" 2>/dev/null)
    _cs_old=$(sed -n 3p "$CAP_FILE" 2>/dev/null)
    _cs_det=$(sed -n 4p "$CAP_FILE" 2>/dev/null)
    _cs_fs=$(sed -n 5p "$CAP_FILE" 2>/dev/null)
  fi
  case "$_cs_ot" in '' | *[!0-9]*) _cs_ot=0 ;; esac
  _cs_ran=0
  if [ "$_cs_had" = 0 ] || [ "$_cs_sig" != "$_cs_osig" ] || [ -n "$_cs_old" ] || \
     [ $((_cs_now - _cs_ot)) -ge "$CAP_RECHECK" ] || [ "$(mono_now)" -lt "$CAP_FAST_UNTIL" ]; then
    # Before boot_completed there is no system_server to ask.
    if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
      # a network came or went (not the first look after boot): Android
      # checks it within seconds - look every 2 s for a while
      [ "$_cs_had" = 1 ] && [ "$_cs_sig" != "$_cs_osig" ] && \
        CAP_FAST_UNTIL=$(( $(mono_now) + CAP_FAST ))
      _cs_det=$(cap_detect | awk '{ printf "%s%s", (NR > 1 ? " " : ""), $0 }')
      _cs_ran=1
    fi
  fi
  # first-seen times, open list
  _cs_nfs=""; _cs_want=""
  for _cs_e in $_cs_det; do
    _cs_n=${_cs_e%%:*}
    _cs_t=""
    for _cs_x in $_cs_fs; do
      [ "${_cs_x%%=*}" = "$_cs_n" ] && { _cs_t=${_cs_x#*=}; break; }
    done
    case "$_cs_t" in '' | *[!0-9]*) _cs_t=$_cs_now ;; esac
    _cs_nfs="$_cs_nfs${_cs_nfs:+ }$_cs_n=$_cs_t"
    _cs_k=${_cs_e%%;*}; _cs_k=${_cs_k##*:}
    if [ "$_cs_k" = login ] || [ $((_cs_now - _cs_t)) -lt "$CAP_WINDOW" ]; then
      _cs_want="$_cs_want${_cs_want:+ }$_cs_e"
    fi
  done
  if [ "$_cs_ran" = 1 ] || [ "$_cs_want" != "$_cs_old" ]; then
    [ "$_cs_ran" = 1 ] || _cs_now=$_cs_ot
    printf '%s\n%s\n%s\n%s\n%s\n' "$_cs_sig" "$_cs_now" "$_cs_want" "$_cs_det" "$_cs_nfs" > "$CAP_FILE" 2>/dev/null
  fi

  _cs_marks=$(for _cs_e in $_cs_want; do printf '0x%x\n' $(( ${_cs_e%%:*} + 65536 )); done | sort | awk '{ printf "%s%s", (NR > 1 ? " " : ""), $0 }')
  _cf_changed=0
  _cap_fill iptables nat "$S4N" "$_cs_marks"
  _cap_fill iptables filter "$S4F" "$_cs_marks"
  # IPv6 only where the IP mode lets the phone use it
  _cs_m6=""
  [ "$(ip_mode_applied | sed 's/-limited$//')" != "ipv4" ] && _cs_m6=$_cs_marks
  [ "$S6OK" = 1 ] && _cap_fill ip6tables filter "$S6F" "$_cs_m6"
  if ip6_redirect_wanted && have_ip6_nat; then
    _cap_fill ip6tables nat "$S6N" "$_cs_m6"
  fi
  [ "$_cf_changed" = 1 ] && ipt_snap_stale
  # routing part: only while the redirect itself is in place (a failsafe
  # or a pause means plain DNS for everyone - nothing to keep out then)
  _cs_v6=0; [ -n "$_cs_m6" ] && _cs_v6=1
  if sn_has "$S4N" "$P_DNAT_UDP" && [ -n "$_cs_want" ]; then
    _cap_routes_apply "$(_cap_routes_want "$_cs_want" "$_cs_v6")"
  else
    cap_routes_clear
  fi

  _cs_lw=$(printf '%s' "$_cs_want" | sed 's/;[^ ]*//g')
  _cs_lo=$(printf '%s' "$_cs_old" | sed 's/;[^ ]*//g')
  if [ "$_cs_lw" != "$_cs_lo" ]; then
    for _cs_e in $_cs_lw; do
      case " $_cs_lo " in *" $_cs_e "*) continue ;; esac
      _cs_i=${_cs_e#*:}; _cs_k=${_cs_i#*:}; _cs_i=${_cs_i%%:*}
      if [ "$_cs_k" = login ]; then
        log_info "Wi-Fi login: $_cs_i (network ${_cs_e%%:*}) has a login page - Android's check and the login page use the network's own DNS until you are logged in"
      else
        log_info "Wi-Fi login: $_cs_i (network ${_cs_e%%:*}) not checked by Android yet - its own DNS answers Android's check meanwhile"
      fi
    done
    for _cs_e in $_cs_lo; do
      _cs_n=${_cs_e%%:*}
      case " $_cs_lw " in *" $_cs_n:"*) continue ;; esac
      _cs_i=${_cs_e#*:}; _cs_i=${_cs_i%%:*}
      if printf ' %s ' "$_cs_det" | grep -q " $_cs_n:"; then
        log_info "Wi-Fi login: $_cs_i (network $_cs_n) not validated by Android after ${CAP_WINDOW}s and no login page - all DNS through the proxy again"
      else
        log_info "Wi-Fi login: $_cs_i (network $_cs_n) checked or gone - all DNS through the proxy again"
      fi
    done
  fi
  unset _cs_sig _cs_now _cs_osig _cs_ot _cs_old _cs_want _cs_marks _cs_m6 _cs_v6 _cs_e _cs_i _cs_k _cs_n _cs_lw _cs_lo _cf_changed \
        _cs_det _cs_fs _cs_nfs _cs_had _cs_ran _cs_t _cs_x
  return 0
}

# 0 while the watchdog should look every 2 s (a network just came or went)
cap_fast() { [ "$(mono_now)" -lt "$CAP_FAST_UNTIL" ]; }
