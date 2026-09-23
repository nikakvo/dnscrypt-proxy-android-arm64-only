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
  [ -f "$IP6_REDIRECT_FILE" ] && read -r _w < "$IP6_REDIRECT_FILE" 2>/dev/null
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
}

# -----------------------------------------------------------------
# Install the DNS redirect + leak guard.
# Inserted in reverse order so the final chain order is:
#   nat OUTPUT:    [bootstrap RETURNs] [udp DNAT] [tcp DNAT] ...
#   filter OUTPUT: [bootstrap ACCEPTs] [udp DROP] [tcp DROP] ...
# -----------------------------------------------------------------
rules_install_dns() {
  iptables -t nat -C OUTPUT -p tcp --dport 53 -j DNAT --to-destination "$DNS_REDIR" 2>/dev/null || \
    iptables -t nat -I OUTPUT 1 -p tcp --dport 53 -j DNAT --to-destination "$DNS_REDIR" 2>/dev/null
  iptables -t nat -C OUTPUT -p udp --dport 53 -j DNAT --to-destination "$DNS_REDIR" 2>/dev/null || \
    iptables -t nat -I OUTPUT 1 -p udp --dport 53 -j DNAT --to-destination "$DNS_REDIR" 2>/dev/null

  if have_owner_match; then
    for _ip in $BOOTSTRAP_IPS; do
      iptables -t nat -C OUTPUT -p tcp -d "$_ip" --dport 53 -m owner --uid-owner 0 -j RETURN 2>/dev/null || \
        iptables -t nat -I OUTPUT 1 -p tcp -d "$_ip" --dport 53 -m owner --uid-owner 0 -j RETURN 2>/dev/null
      iptables -t nat -C OUTPUT -p udp -d "$_ip" --dport 53 -m owner --uid-owner 0 -j RETURN 2>/dev/null || \
        iptables -t nat -I OUTPUT 1 -p udp -d "$_ip" --dport 53 -m owner --uid-owner 0 -j RETURN 2>/dev/null
    done
    unset _ip
  fi

  # Leak guard: anything on port 53 that did NOT get redirected and is
  # not going to loopback is, by definition, plaintext DNS escaping the
  # proxy. Drop it. Only installed when the bootstrap exemption above
  # could also be installed - without xt_owner this rule would block the
  # daemon itself if sources were ever re-enabled, and failing open beats
  # bricking DNS.
  if have_owner_match; then
    iptables -C OUTPUT ! -o lo -p tcp --dport 53 -j DROP 2>/dev/null || \
      iptables -I OUTPUT 1 ! -o lo -p tcp --dport 53 -j DROP 2>/dev/null
    iptables -C OUTPUT ! -o lo -p udp --dport 53 -j DROP 2>/dev/null || \
      iptables -I OUTPUT 1 ! -o lo -p udp --dport 53 -j DROP 2>/dev/null
    for _ip in $BOOTSTRAP_IPS; do
      iptables -C OUTPUT ! -o lo -p tcp -d "$_ip" --dport 53 -m owner --uid-owner 0 -j ACCEPT 2>/dev/null || \
        iptables -I OUTPUT 1 ! -o lo -p tcp -d "$_ip" --dport 53 -m owner --uid-owner 0 -j ACCEPT 2>/dev/null
      iptables -C OUTPUT ! -o lo -p udp -d "$_ip" --dport 53 -m owner --uid-owner 0 -j ACCEPT 2>/dev/null || \
        iptables -I OUTPUT 1 ! -o lo -p udp -d "$_ip" --dport 53 -m owner --uid-owner 0 -j ACCEPT 2>/dev/null
    done
    unset _ip
  fi

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
