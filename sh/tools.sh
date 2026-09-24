#!/system/bin/sh
# shellcheck shell=sh disable=SC2034
#
# sh/tools.sh - domain check, allow/block rules, live query.
# Sourced after sh/common.sh and sh/blocklist.sh by ctl.sh. Defines only.

ALLOW_FILE="$DATA_DIR/allowed-names.txt"

# A plain domain name, lowercased. Rejects anything else, so nothing that
# reaches a rule file can be a pattern by accident or carry shell syntax.
valid_domain() { # <name> -> prints the normalised name, or fails
  _vd=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  _vd=${_vd#\*.}; _vd=${_vd#.}; _vd=${_vd%.}
  case "$_vd" in
    '' | *[!a-z0-9._-]* | .* | *..* | -*) unset _vd; return 1 ;;
    *.*) : ;;
    *) unset _vd; return 1 ;;
  esac
  [ "${#_vd}" -le 253 ] || { unset _vd; return 1; }
  echo "$_vd"
  unset _vd
}

# ── Rule matching, the way dnscrypt-proxy does it (pattern_matcher.go) ──────
# Prints the first rule in the file(s) that matches <domain>, as written,
# or nothing. Handles plain/suffix, *.suffix, =exact, prefix*, *substring*
# and globs (? [] or * in the middle).
rule_match() { # <domain> <file>...
  _rd=$1; shift
  awk -v d="$_rd" '
    function glob2re(g,   i, c, r) {
      r = "^"
      for (i = 1; i <= length(g); i++) {
        c = substr(g, i, 1)
        if (c == "*") r = r ".*"
        else if (c == "?") r = r "."
        else if (c == ".") r = r "[.]"
        else r = r c
      }
      return r "$"
    }
    {
      sub(/\r$/, ""); sub(/[ \t]*#.*$/, ""); gsub(/^[ \t]+|[ \t]+$/, "")
      if ($0 == "") next
      r = tolower($0); p = r
      lead = (substr(p, 1, 1) == "*"); trail = (substr(p, length(p), 1) == "*")
      mid = substr(p, 2, length(p) - 2)
      if (index(p, "?") || index(p, "[") || (index(mid, "*") && length(p) > 2)) {
        if (d ~ glob2re(p)) { print r; exit }
      } else if (lead && trail && length(p) > 2) {
        if (index(d, mid) > 0) { print r; exit }
      } else if (trail) {
        if (index(d, substr(p, 1, length(p) - 1)) == 1) { print r; exit }
      } else if (substr(p, 1, 1) == "=") {
        if (d == substr(p, 2)) { print r; exit }
      } else {
        if (lead) p = substr(p, 2)
        if (substr(p, 1, 1) == ".") p = substr(p, 2)
        if (d == p) { print r; exit }
        n = length(d) - length(p)
        if (n > 0 && substr(d, n) == "." p) { print r; exit }
      }
    }' "$@" 2>/dev/null
  unset _rd
}

# Which cached sources (and the custom list) contain <rule> as a name.
rule_origins() { # <rule>
  _ro=$1
  case "$_ro" in *[!a-z0-9._-]*) unset _ro; return 0 ;; esac
  for _f in "$BL_SRC_DIR"/*.txt; do
    [ -f "$_f" ] || continue
    grep -qxF "$_ro" "$_f" 2>/dev/null && basename "$_f" .txt
  done
  if [ -f "$BL_CUSTOM" ] && bl_normalize 1 < "$BL_CUSTOM" | grep -qxF "$_ro"; then
    echo "custom"
  fi
  unset _ro _f
}

# ── Live query ───────────────────────────────────────────────────────────────
# Ask the running daemon directly (127.0.0.1:5354, no redirect involved) and
# decode the answer: rcode, answer count, first answer type, first IPv4.
_qname_bytes() { # <domain> -> DNS wire-format name, octal-escaped for printf
  _qn=""
  _rest=$1
  while [ -n "$_rest" ]; do
    _lab=${_rest%%.*}
    if [ "$_lab" = "$_rest" ]; then _rest=""; else _rest=${_rest#*.}; fi
    _qn="$_qn\\$(printf '%03o' "${#_lab}")$_lab"
  done
  printf '%s\\000' "$_qn"
  unset _qn _rest _lab
}

# Stop a background probe pipeline stage and everything under it (the
# subshell, timeout, nc - and busybox timeout's own watcher process).
# Children are found through /proc/PID/task/PID/children; on a kernel
# without it only the stage itself is stopped and nc ends at its timeout.
_lq_kill() { # <pid> [depth]
  if [ "${2:-0}" -lt 4 ]; then
    for _c in $(cat "/proc/$1/task/$1/children" 2>/dev/null); do
      _lq_kill "$_c" $((${2:-0} + 1))
    done
  fi
  kill "$1" 2>/dev/null
}

live_query() { # <domain> -> key=value lines
  _tool=""
  [ -n "$BB" ] && _nc_has_udp "$BB" nc && _tool="bb"
  [ -z "$_tool" ] && command -v nc >/dev/null 2>&1 && _nc_has_udp nc && _tool="nc"
  if [ -z "$_tool" ]; then echo "live=unavailable"; unset _tool; return 0; fi
  # shellcheck disable=SC2059
  _pkt="\\022\\064\\001\\000\\000\\001\\000\\000\\000\\000\\000\\000$(_qname_bytes "$1")\\000\\001\\000\\001"
  # -w for busybox nc, -q for toybox nc: see _nc_wait_flag in common.sh.
  # Both keep waiting for more data after the reply is in, so nc runs in
  # the background and is stopped as soon as the answer has arrived: the
  # Check button answers in a fraction of a second instead of 3-6.
  if [ "$_tool" = "bb" ]; then
    set -- "$BB" nc
  else
    set -- nc
  fi
  _fl=$(_nc_wait_flag "$@")
  rm -f "$STATE_DIR/.lq"
  # shellcheck disable=SC2059
  printf "$_pkt" | _nc_run 3 "$@" -u "-$_fl" 3 "$LISTEN_ADDR" "$LISTEN_PORT" > "$STATE_DIR/.lq" &
  _lqp=$!
  _i=0
  while [ "$_i" -lt 40 ] && kill -0 "$_lqp" 2>/dev/null; do
    [ -s "$STATE_DIR/.lq" ] && { sleep 0.1 2>/dev/null; break; }
    sleep 0.1 2>/dev/null || sleep 1
    _i=$((_i + 1))
  done
  _lq_kill "$_lqp"
  wait "$_lqp" 2>/dev/null
  if [ ! -s "$STATE_DIR/.lq" ]; then
    echo "live=noreply"
  else
    od -An -tu1 -v "$STATE_DIR/.lq" | awk '
      { for (i = 1; i <= NF; i++) b[n++] = $i }
      END {
        if (n < 12) { print "live=invalid"; exit }
        rc = b[3] % 16; an = b[6] * 256 + b[7]
        names[0] = "NOERROR"; names[1] = "FORMERR"; names[2] = "SERVFAIL"; names[3] = "NXDOMAIN"; names[5] = "REFUSED"
        print "live=reply"
        print "live_rcode=" (rc in names ? names[rc] : rc)
        print "live_answers=" an
        if (an == 0) exit
        p = 12
        while (p < n && b[p] != 0) p += b[p] + 1
        p += 5
        if (b[p] >= 192) p += 2; else { while (p < n && b[p] != 0) p += b[p] + 1; p++ }
        t = b[p] * 256 + b[p + 1]
        tn = (t == 1 ? "A" : t == 5 ? "CNAME" : t == 13 ? "HINFO" : t == 28 ? "AAAA" : t)
        print "live_type=" tn
        if (t == 1 && b[p + 8] * 256 + b[p + 9] == 4) print "live_ip=" b[p+10] "." b[p+11] "." b[p+12] "." b[p+13]
      }'
  fi
  rm -f "$STATE_DIR/.lq"
  unset _tool _pkt _fl _lqp _i
}

# ── Allow / block ────────────────────────────────────────────────────────────
# Append a line to a rule file, making sure the file ends in a newline
# first (allowed-names.txt ships with CRLF and no final newline).
_append_rule() { # <file> <rule>
  if [ -s "$1" ] && [ "$(tail -c 1 "$1" | od -An -tu1 | tr -d ' ')" != "10" ]; then
    echo "" >> "$1"
  fi
  echo "$2" >> "$1"
}

# Remove a rule however it was written: name, *.name or .name, CRLF or not.
_remove_rule() { # <file> <name>
  [ -f "$1" ] || return 1
  awk -v n="$2" '{
      l = $0; sub(/\r$/, "", l); sub(/[ \t]*#.*$/, "", l); gsub(/^[ \t]+|[ \t]+$/, "", l)
      l = tolower(l)
      if (l == n || l == "*." n || l == "." n) { hit = 1; next }
      print
    } END { exit !hit }' "$1" > "$1.tmp" && mv -f "$1.tmp" "$1" && return 0
  rm -f "$1.tmp"
  return 1
}

_has_rule() { # <file> <name>
  [ -f "$1" ] || return 1
  bl_normalize 1 < "$1" | grep -qxF "$2"
}
