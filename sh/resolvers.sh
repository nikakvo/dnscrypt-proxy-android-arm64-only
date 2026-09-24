#!/system/bin/sh
# shellcheck shell=sh disable=SC2034
#
# sh/resolvers.sh - choosing upstream resolvers.
# Sourced after sh/common.sh by ctl.sh. Defines only.
#
# Stamps come from public-resolvers.md as shipped with the module (the
# signed list from the DNSCrypt project), never typed in by hand. The
# properties shown in the WebUI - protocol, DNSSEC, no-log, no-filter - are
# decoded from the stamp itself, which is what the resolver operator
# declares, not a description someone wrote about it.

RES_MD="$DATA_DIR/public-resolvers.md"

# Well-known choices shown first. Any other entry of the 500+ in
# public-resolvers.md can be found with the search.
RES_CURATED="cloudflare cloudflare-security quad9-dnscrypt-ip4-nofilter-pri quad9-doh-ip4-port443-nofilter-pri quad9-doh-ip4-port443-filter-pri mullvad-base-doh mullvad-doh mullvad-adblock-doh adguard-dns-doh adguard-dns-unfiltered-doh nextdns controld-uncensored libredns dnscry.pt-frankfurt-ipv4 google cisco"

res_md() {
  if [ -f "$RES_MD" ]; then echo "$RES_MD"; else echo "$MODDIR/config/public-resolvers.md"; fi
}

# First stamp of <name> in public-resolvers.md.
res_stamp() { # <name>
  awk -v n="## $1" '$0 == n { f = 1; next } f && /^## / { exit } f && /^sdns:\/\// { print; exit }' "$(res_md)" 2>/dev/null
}

# First description line of <name>.
res_desc() { # <name>
  awk -v n="## $1" '$0 == n { f = 1; next } f && /^## / { exit } f && NF && !/^sdns:/ && !/^https?:/ { print; exit }' "$(res_md)" 2>/dev/null
}

res_exists() { grep -qxF "## $1" "$(res_md)" 2>/dev/null; }

# Decode a stamp: proto|dnssec|nolog|nofilter|address
#   proto 1 = DNSCrypt, 2 = DoH, 3 = DoT, 5 = ODoH target ...
#   props bit 0 = DNSSEC, bit 1 = no logs, bit 2 = no filter
res_decode() { # <sdns://...>
  _b=${1#sdns://}
  _b=$(printf '%s' "$_b" | tr -- '-_' '+/')
  case $(( ${#_b} % 4 )) in 2) _b="$_b==" ;; 3) _b="$_b=" ;; esac
  printf '%s' "$_b" | base64 -d 2>/dev/null | od -An -tu1 -v | awk '
    { for (i = 1; i <= NF; i++) b[n++] = $i }
    END {
      if (n < 10) exit
      pr = b[0]
      pn = (pr == 1 ? "DNSCrypt" : pr == 2 ? "DoH" : pr == 3 ? "DoT" : pr == 5 ? "ODoH" : "other")
      props = b[1]
      len = b[9]; a = ""
      for (i = 0; i < len; i++) a = a sprintf("%c", b[10 + i])
      printf "%s|%d|%d|%d|%s\n", pn, props % 2, int(props / 2) % 2, int(props / 4) % 2, a
    }'
  unset _b
}

# Names currently in server_names in the toml, one per line.
res_current() {
  awk '
    /^server_names[ \t]*=/ { on = 1 }
    on { s = s $0 }
    on && /\]/ { exit }
    END {
      while (match(s, /\047[^\047]+\047/)) {
        print substr(s, RSTART + 1, RLENGTH - 2)
        s = substr(s, RSTART + RLENGTH)
      }
    }' "$CONFIG" 2>/dev/null
}

# One line per resolver for the WebUI:
#   res=name|curated|selected|proto|dnssec|nolog|nofilter|address|description
res_list() {
  _cur=" $(res_current | tr '\n' ' ') "
  _all="$RES_CURATED"
  for _n in $(res_current); do
    case " $RES_CURATED " in *" $_n "*) : ;; *) _all="$_all $_n" ;; esac
  done
  for _n in $_all; do
    _st=$(res_stamp "$_n")
    [ -n "$_st" ] || continue
    case " $RES_CURATED " in *" $_n "*) _c=1 ;; *) _c=0 ;; esac
    case "$_cur" in *" $_n "*) _s=1 ;; *) _s=0 ;; esac
    echo "res=$_n|$_c|$_s|$(res_decode "$_st")|$(res_desc "$_n" | tr '|' '/')"
  done
  unset _cur _all _n _st _c _s
}

res_search() { # <term> -> up to 40 matching names (name or description)
  awk -v t="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" '
    /^## / { name = substr($0, 4); getline d; if (index(tolower(name " " d), t)) print name }' "$(res_md)" 2>/dev/null |
    head -n 40
}

# Rewrite server_names and the [static] block (always the last section of
# the module's toml), check the result with the daemon's own parser, and
# only then replace the live config. Returns 1 with a message on failure.
res_apply() { # <name> ... (already validated)
  _names=""
  for _n in "$@"; do _names="$_names${_names:+, }'$_n'"; done
  _tmp="$DATA_DIR/.dnscrypt-proxy.toml.new"
  awk -v names="$_names" '
    skip && /\]/ { skip = 0; next }
    skip { next }
    /^server_names[ \t]*=/ {
      print "server_names = [" names "]"
      if ($0 !~ /\]/) skip = 1
      next
    }
    /^\[static\]/ { exit }
    { print }' "$CONFIG" > "$_tmp"
  {
    echo "[static]"
    echo ""
    echo "## Managed by the module (WebUI -> Tools -> Resolvers). Every server in"
    echo "## server_names is pinned here with its stamp from public-resolvers.md,"
    echo "## so the daemon starts without downloading a source list."
    for _n in "$@"; do
      echo ""
      echo "[static.'$_n']"
      echo "stamp = '$(res_stamp "$_n")'"
    done
  } >> "$_tmp"

  _chk=$(cd "$DATA_DIR" && "$DNSCRYPT_BIN" -config "$_tmp" -check 2>&1)
  if [ $? -ne 0 ]; then
    rm -f "$_tmp"
    RES_ERROR=$(printf '%s' "$_chk" | tail -n 1)
    unset _names _n _tmp _chk
    return 1
  fi
  cp -f "$CONFIG" "$DATA_DIR/dnscrypt-proxy.toml.bak" 2>/dev/null
  mv -f "$_tmp" "$CONFIG"
  mirror_to_sd dnscrypt-proxy.toml
  unset _names _n _tmp _chk
  return 0
}

# Can this netcat do a connect-only probe (-z)? Help formats differ.
_nc_has_zero() {
  { "$@" --help; "$@" -h; } 2>&1 | grep -qiE ' -z|zero-i/o'
}

# TCP connect time to each resolver's address, in ms (10 ms resolution),
# all measured in parallel. A rough but honest proxy for "how far away":
# the handshake is one round trip. Prints name=ms, or name=fail.
res_latency() { # <name> ...
  _nc=""
  if [ -n "$BB" ] && _nc_has_zero "$BB" nc; then _nc="$BB nc"
  elif command -v nc >/dev/null 2>&1 && _nc_has_zero nc; then _nc="nc"
  fi
  if [ -z "$_nc" ]; then
    for _n in "$@"; do echo "$_n=na"; done
    unset _nc _n
    return 0
  fi
  _dir="$STATE_DIR/.lat"; rm -rf "$_dir"; mkdir -p "$_dir"
  for _n in "$@"; do
    (
      _a=$(res_decode "$(res_stamp "$_n")" | cut -d'|' -f5)
      case "$_a" in
        # No address in the stamp (a DoH server known only by host name) or
        # an IPv6 one: nothing to time without a DNS lookup - say so
        # instead of reporting a failure.
        '' | \[*) echo na > "$_dir/$_n"; exit 0 ;;
        *:*) _h=${_a%:*}; _p=${_a##*:} ;;
        *)   _h=$_a; _p=443 ;;
      esac
      _t0=$(cs_now)
      # shellcheck disable=SC2086
      if _nc_run 2 $_nc -z -w 2 "$_h" "$_p" < /dev/null > /dev/null; then
        echo "$(( ($(cs_now) - _t0) * 10 ))" > "$_dir/$_n"
      else
        echo fail > "$_dir/$_n"
      fi
    ) &
  done
  wait
  for _n in "$@"; do echo "$_n=$(cat "$_dir/$_n" 2>/dev/null || echo fail)"; done
  rm -rf "$_dir"
  unset _nc _n _dir
}
