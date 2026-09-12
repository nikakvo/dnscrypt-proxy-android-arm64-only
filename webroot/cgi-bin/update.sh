#!/system/bin/sh
# CGI: POST /cgi-bin/update.sh → starts update-blocklist.sh detached

printf 'Content-Type: application/json\r\n'
printf 'Access-Control-Allow-Origin: *\r\n'
printf '\r\n'

# -----------------------------------------------
# State-changing endpoint: require POST.
#
# Worth being honest about the limit here: this server listens on
# 127.0.0.1 with no authentication, and loopback is NOT privileged
# on Android - any installed app can reach it. A token would not
# fix that either, since the same app could just fetch index.html
# and read the token out of it. What POST-only does buy is that a
# WebView or browser cannot be walked into triggering this by
# following a link or loading an <img> tag, which is the realistic
# drive-by path. The endpoint itself is deliberately harmless: it
# only refreshes a public blocklist.
# -----------------------------------------------
if [ "${REQUEST_METHOD:-GET}" != "POST" ]; then
  printf '{"ok":false,"msg":"POST required"}'
  exit 0
fi

ACTION_SH="/data/adb/modules/dnscrypt-proxy-android/update-blocklist.sh"
ACTION_LOG="/data/adb/dnscrypt-action.log"

if [ ! -f "$ACTION_SH" ]; then
  printf '{"ok":false,"msg":"update-blocklist.sh not found"}'
  exit 0
fi

# Check if already running
if pgrep -f "update-blocklist\.sh" >/dev/null 2>&1; then
  printf '{"ok":false,"msg":"Update already running"}'
  exit 0
fi

# Start detached — setsid prevents kill when httpd closes the CGI
(setsid sh "$ACTION_SH" > "$ACTION_LOG" 2>&1 &)

printf '{"ok":true,"msg":"Update started"}'
