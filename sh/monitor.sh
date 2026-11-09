#!/system/bin/sh
# Login of dnscrypt-proxy's monitoring page (127.0.0.1:5555).
#
# Without a password any app on the phone could read the page (loopback is
# shared by every app): the last queried names and the top domains. So the
# installer gives it a user and a random password, kept across updates; a
# login the user set by hand is never replaced. The values live where the
# daemon reads them: [monitoring_ui] username / password in the toml.
#
# The sdcard mirror of the toml is readable by apps with file access, so it
# carries MON_PLACEHOLDER instead of the password. A toml synced back from
# the sdcard with the placeholder (or an empty password) gets the current
# password again; a real password typed there is taken.
#
# Standalone on purpose (awk + od only): customize.sh sources it too.
# Values go to awk through ENVIRON, never -v (which would eat backslashes).

MON_USER_DEFAULT="dnscrypt"
MON_PLACEHOLDER="set by the module - see the WebUI"

# mon_get <toml> - sets MON_USER and MON_PASS (empty when missing)
mon_get() {
  MON_USER=""; MON_PASS=""
  [ -f "$1" ] || return 1
  _mg=$(awk '
    /^[ \t]*\[/ { s = ($0 ~ /^[ \t]*\[monitoring_ui\][ \t]*$/) }
    s && /^[ \t]*(username|password)[ \t]*=/ {
      k = $0; sub(/[ \t]*=.*$/, "", k); gsub(/[ \t]/, "", k)
      v = $0; sub(/^[^=]*=[ \t]*/, "", v)
      if (match(v, /^"[^"]*"/)) v = substr(v, 2, RLENGTH - 2)
      else if (match(v, /^\047[^\047]*\047/)) v = substr(v, 2, RLENGTH - 2)
      else v = ""
      print k "=" v
    }' "$1" 2>/dev/null)
  _mo=$IFS; IFS='
'
  for _ml in $_mg; do
    case "$_ml" in
      username=*) MON_USER=${_ml#username=} ;;
      password=*) MON_PASS=${_ml#password=} ;;
    esac
  done
  IFS=$_mo
  unset _mg _ml _mo
  return 0
}

# mon_pass_ok <password> - a real password (not empty, not the placeholder,
# no character that would break the toml string)
mon_pass_ok() {
  [ -n "$1" ] && [ "$1" != "$MON_PLACEHOLDER" ] || return 1
  case "$1" in *\"*|*\\*) return 1 ;; esac
  return 0
}

# mon_gen - 16 random letters and digits
mon_gen() {
  od -An -tu1 -N32 /dev/urandom 2>/dev/null | awk '
    BEGIN { c = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"; n = length(c) }
    { for (i = 1; i <= NF; i++) if (length(s) < 16) { x = $i - int($i / n) * n; s = s substr(c, x + 1, 1) } }
    END { print s }'
}

# mon_set <toml> <user> <password> - write both into [monitoring_ui]
mon_set() {
  [ -f "$1" ] || return 1
  MON_U="$2" MON_P="$3" awk '
    function out_missing() { if (!du) print "username = \"" ENVIRON["MON_U"] "\""; if (!dp) print "password = \"" ENVIRON["MON_P"] "\""; du = dp = 1 }
    /^[ \t]*\[/ {
      if (s) out_missing()
      s = ($0 ~ /^[ \t]*\[monitoring_ui\][ \t]*$/)
      print; next
    }
    s && /^[ \t]*username[ \t]*=/ { print "username = \"" ENVIRON["MON_U"] "\""; du = 1; next }
    s && /^[ \t]*password[ \t]*=/ { print "password = \"" ENVIRON["MON_P"] "\""; dp = 1; next }
    { print }
    END { if (s) out_missing() }' "$1" > "$1.mon.$$" && mv -f "$1.mon.$$" "$1"
}

# mon_ensure <toml> [<previous toml>] - the toml gets a usable login:
# its own when it has one, else the previous file's, else a new one.
# Sets MON_NEW=1 when a new password was made.
mon_ensure() {
  MON_NEW=0
  mon_get "$1" || return 1
  mon_pass_ok "$MON_PASS" && [ -n "$MON_USER" ] && return 0
  _me_u=$MON_USER
  if [ -n "$2" ] && mon_get "$2" && mon_pass_ok "$MON_PASS" && [ -n "$MON_USER" ]; then
    mon_set "$1" "$MON_USER" "$MON_PASS"
  else
    MON_USER=${_me_u:-$MON_USER_DEFAULT}
    MON_PASS=$(mon_gen)
    [ "${#MON_PASS}" -ge 12 ] || { unset _me_u; return 1; }
    mon_set "$1" "$MON_USER" "$MON_PASS"
    MON_NEW=1
  fi
  unset _me_u
}

# mon_sd_copy <toml> <destination> - the toml with the password masked
mon_sd_copy() {
  MON_P="$MON_PLACEHOLDER" awk '
    /^[ \t]*\[/ { s = ($0 ~ /^[ \t]*\[monitoring_ui\][ \t]*$/) }
    s && /^[ \t]*password[ \t]*=/ { print "password = \"" ENVIRON["MON_P"] "\""; next }
    { print }' "$1" > "$2"
}
