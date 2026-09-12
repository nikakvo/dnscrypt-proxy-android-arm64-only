#!/system/bin/sh
# CGI: GET /cgi-bin/status.sh → returns {"running","last_update"}

printf 'Content-Type: application/json\r\n'
printf 'Access-Control-Allow-Origin: *\r\n'
printf '\r\n'

LAST_UPDATE_FILE="/storage/emulated/0/dnscrypt-proxy/.last_update"

if pgrep -f "update-blocklist\.sh" >/dev/null 2>&1; then
  RUNNING="true"
else
  RUNNING="false"
fi

if [ -f "$LAST_UPDATE_FILE" ]; then
  LAST_UPDATE=$(cat "$LAST_UPDATE_FILE" 2>/dev/null | tr -d '\n')
  [ -z "$LAST_UPDATE" ] && LAST_UPDATE="—"
else
  LAST_UPDATE="—"
fi

printf '{"running":%s,"last_update":"%s"}' "$RUNNING" "$LAST_UPDATE"
