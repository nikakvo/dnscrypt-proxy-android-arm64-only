#!/system/bin/sh
# CGI: GET /cgi-bin/log.sh → returns last 80 lines of action log

ACTION_LOG="/data/adb/dnscrypt-action.log"

printf 'Content-Type: text/plain; charset=utf-8\r\n'
printf 'Access-Control-Allow-Origin: *\r\n'
printf '\r\n'

tail -n 80 "$ACTION_LOG" 2>/dev/null || printf '(log empty)'
