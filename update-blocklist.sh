#!/system/bin/sh
# update-blocklist.sh - Blocklist updater
# Triggered by the "Update Blocklist" button in the module's Web UI
# via the busybox httpd CGI server (webroot/cgi-bin/update.sh)

# -----------------------------------------------
# r11: the blocklist now lives on /data, not the sdcard.
# It is 7.6 MB and the daemon reads it on every start and every SIGHUP;
# doing that across FUSE was slow, and doing it from a filesystem that
# may not be mounted yet at boot was the reason the daemon sometimes
# never came up at all.
#
# custom-blocked-names.txt is still edited on the sdcard, so take
# whichever copy is newer.
# -----------------------------------------------
DATA_DIR="/data/adb/dnscrypt-proxy"
SD_DIR="/storage/emulated/0/dnscrypt-proxy"
BLOCKLIST="$DATA_DIR/blocked-names.txt"
CUSTOM="$DATA_DIR/custom-blocked-names.txt"
LAST_UPDATE_FILE="$DATA_DIR/.last_update"
TMP="$DATA_DIR/blocklist.tmp"
LOG="/data/adb/dnscrypt-proxy.log"
URL_1="https://big.oisd.nl/domainswild2"
URL_2="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.plus-onlydomains.txt"
URL_3="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/ultimate-onlydomains.txt"
UPDATE_FLAG="$DATA_DIR/.update_ok"

mtime_of() { stat -c %Y "$1" 2>/dev/null || echo 0; }

# Pull in a newer sdcard copy of the custom list before merging.
# Also honours the old misspelling from r8 and earlier.
if [ -d "$SD_DIR" ]; then
  if [ -f "$SD_DIR/gustum-blocked-names.txt" ] && [ ! -f "$SD_DIR/custom-blocked-names.txt" ]; then
    mv -f "$SD_DIR/gustum-blocked-names.txt" "$SD_DIR/custom-blocked-names.txt" 2>/dev/null
  fi
  if [ -f "$SD_DIR/custom-blocked-names.txt" ]; then
    if [ ! -f "$CUSTOM" ] || [ "$(mtime_of "$SD_DIR/custom-blocked-names.txt")" -gt "$(mtime_of "$CUSTOM")" ]; then
      cp -f "$SD_DIR/custom-blocked-names.txt" "$CUSTOM" 2>/dev/null
      echo "* Picked up newer custom-blocked-names.txt from sdcard"
    fi
  fi
fi

cleanup() {
  kill $CURL_PID 2>/dev/null
  rm -f "$TMP" 2>/dev/null
  [ ! -f "$UPDATE_FLAG" ] && rm -f "${BLOCKLIST}.new" 2>/dev/null
  rm -f "$UPDATE_FLAG" 2>/dev/null
}
trap cleanup EXIT INT TERM

progress_bar() {
  current=$1
  total=$2
  width=38
  [ "$total" -eq 0 ] && total=1
  pct=$(( current * 100 / total ))
  [ "$pct" -gt 99 ] && pct=99
  filled=$(( pct * width / 100 ))
  bar="" ; i=0
  while [ $i -lt $filled ]; do bar="${bar}█"; i=$(( i + 1 )); done
  while [ $i -lt $width  ]; do bar="${bar}░"; i=$(( i + 1 )); done
  echo "  [${bar}] ${pct}%"
}

echo " "
echo "************************************"
echo "*   DNSCrypt Blocklist Updater     *"
echo "************************************"
echo " "

if [ ! -d "$DATA_DIR" ]; then
  echo "! ERROR: runtime directory not found: $DATA_DIR"
  echo "! Is the module installed and rebooted?"
  exit 1
fi

OLD_COUNT=0
[ -f "$BLOCKLIST" ] && OLD_COUNT=$(wc -l < "$BLOCKLIST" 2>/dev/null || echo 0)

echo "-----------------------------------------------"
echo "  Current blocklist: $OLD_COUNT domains"
echo "-----------------------------------------------"
echo " "

get_expected() {
  url="$1"
  len=$(curl -sI --max-time 10 --connect-timeout 8 "$url" 2>/dev/null \
        | grep -i "^content-length:" | tail -1 \
        | tr -d '[:space:]\r' | cut -d: -f2)
  echo "$len" | grep -qE '^[0-9]+$' && [ "$len" -gt 0 ] \
    && echo "$len" || echo "20971520"
}

download_list() {
  url="$1"
  label="$2"
  echo "* Trying: $label"
  echo " "

  EXPECTED=$(get_expected "$url")

  rm -f "$TMP"
  curl -s --max-time 300 --connect-timeout 15 "$url" -o "$TMP" 2>/dev/null &
  CURL_PID=$!
  PREV_PCT=-1
  while kill -0 $CURL_PID 2>/dev/null; do
    if [ -f "$TMP" ]; then
      SIZE=$(wc -c < "$TMP" 2>/dev/null || echo 0)
      PCT=$(( SIZE * 100 / EXPECTED ))
      [ "$PCT" -gt 99 ] && PCT=99
      PCT5=$(( PCT / 5 * 5 ))
      PREV5=$(( PREV_PCT / 5 * 5 ))
      if [ "$PCT5" -ne "$PREV5" ] || [ "$PREV_PCT" -eq -1 ]; then
        progress_bar "$SIZE" "$EXPECTED"
        PREV_PCT=$PCT
      fi
    fi
    sleep 1
  done
  wait $CURL_PID
  ret=$?
  if [ $ret -eq 0 ] && [ -s "$TMP" ]; then
    return 0
  fi
  rm -f "$TMP"
  echo "! Failed: $label"
  echo " "
  return 1
}

download_list "$URL_1" "OISD Big" || \
download_list "$URL_2" "hagezi pro.plus" || \
download_list "$URL_3" "hagezi ultimate" || {
  echo " "
  echo "! ERROR: All sources failed!"
  echo "! Check your internet connection."
  exit 1
}

echo "* Download complete!"
echo " "

DL_COUNT=$(wc -l < "$TMP" 2>/dev/null || echo 0)
echo "  Downloaded : $DL_COUNT domains"
echo "  Existing   : $OLD_COUNT domains"
echo " "

echo "-----------------------------------------------"
echo "* Step 1/2 - Cleaning downloaded list..."
echo "-----------------------------------------------"
sed -i '/^#/d;/^$/d' "$TMP"
sed -i 's|^\([^*]\)|\*.\1|' "$TMP"
echo "* Done."
echo " "

echo "-----------------------------------------------"
echo "* Step 2/2 - Merging & deduplicating..."
echo "* (please wait)"
echo "-----------------------------------------------"
if [ -f "$CUSTOM" ] && [ -s "$CUSTOM" ]; then
  CUSTOM_COUNT=$(grep -cv '^#\|^$' "$CUSTOM" 2>/dev/null || echo 0)
  echo "* custom-blocked-names.txt found: $CUSTOM_COUNT domains — merging..."
  CUSTOM_NORM="$DATA_DIR/custom.tmp"
  sed '/^#/d;/^$/d' "$CUSTOM" | sed 's|^\([^*]\)|\*.\1|' > "$CUSTOM_NORM"
  { cat "$TMP"; cat "$CUSTOM_NORM"; } | sort | uniq > "${BLOCKLIST}.new"
  rm -f "$CUSTOM_NORM"
else
  echo "* No custom-blocked-names.txt found — skipping."
  sort "$TMP" | uniq > "${BLOCKLIST}.new"
fi
rm -f "$TMP"
echo "* Done."
echo " "

NEW_COUNT=$(wc -l < "${BLOCKLIST}.new" 2>/dev/null || echo 0)
ADDED=$(( NEW_COUNT - OLD_COUNT ))

# Sanity floor: a real OISD/hagezi pull runs in the hundreds of
# thousands. This only catches a truncated fetch or a format change
# that would otherwise silently replace a working list with garbage.
MIN_SANE_COUNT=1000

if [ "$NEW_COUNT" -ge "$MIN_SANE_COUNT" ]; then
  mv "${BLOCKLIST}.new" "$BLOCKLIST"
  touch "$UPDATE_FLAG"
  # Record what the custom list looked like at merge time. service.sh
  # compares against this to work out which custom entries were deleted
  # by hand; without refreshing it here, the next sync would see a stale
  # snapshot and try to strip entries this run just added.
  if [ -f "$CUSTOM" ]; then
    sed '/^#/d;/^$/d' "$CUSTOM" 2>/dev/null | sed 's|^\([^*]\)|\*.\1|' | sort -u > "$DATA_DIR/.custom.merged"
  else
    : > "$DATA_DIR/.custom.merged"
  fi
  date '+%Y-%m-%d %H:%M:%S' > "$LAST_UPDATE_FILE"

  CUSTOM_FINAL=0
  [ -f "$CUSTOM" ] && [ -s "$CUSTOM" ] && CUSTOM_FINAL=$(grep -cv '^#\|^$' "$CUSTOM" 2>/dev/null || echo 0)

  echo "-----------------------------------------------"
  echo "  Downloaded : $DL_COUNT domains"
  echo "  Custom     : +$CUSTOM_FINAL domains"
  echo "  Final      : $NEW_COUNT domains (after dedup)"
  echo "-----------------------------------------------"
  echo " "

  ADDED_DISPLAY="$ADDED"
  [ "$ADDED" -ge 0 ] && ADDED_DISPLAY="+$ADDED"
  echo "$(date): Blocklist updated: $OLD_COUNT -> $NEW_COUNT ($ADDED_DISPLAY)" >> "$LOG"

  echo "* Reloading dnscrypt-proxy (SIGHUP)..."
  pkill -HUP -x dnscrypt-proxy 2>/dev/null
  sleep 2

  WAIT=0
  while [ $WAIT -lt 15 ]; do
    if ss -ulnp 2>/dev/null | grep -q ":5354" || \
       netstat -ulnp 2>/dev/null | grep -q ":5354" || \
       awk 'NR>1 && $2 ~ /:14EA$/ {found=1; exit} END {exit !found}' /proc/net/udp 2>/dev/null; then
      echo "* dnscrypt-proxy reloaded successfully — no downtime!"
      break
    fi
    sleep 1
    WAIT=$((WAIT + 1))
  done

  [ "$WAIT" -ge 15 ] && echo "* dnscrypt-proxy will restart via watchdog shortly."
else
  rm -f "${BLOCKLIST}.new"
  echo "! ERROR: Result has only $NEW_COUNT domains (expected hundreds of thousands) — keeping existing blocklist."
  echo "$(date): Blocklist action: result too small ($NEW_COUNT, min $MIN_SANE_COUNT), kept existing ($OLD_COUNT)" >> "$LOG"
fi

rm -f "$TMP"

echo " "
echo "************************************"
echo "*           Done!                  *"
echo "************************************"
echo " "
