#!/system/bin/sh
# update-blocklist.sh - Blocklist updater
# Triggered by the "Update Blocklist" button in the module's Web UI (index.html)
# via the busybox httpd CGI server (webroot/cgi-bin/update.sh)
# Renamed from action.sh so it no longer shows as a SukiSU Manager Action button —
# update is now controlled entirely through the Web UI.

DNSCRYPT_DIR="/storage/emulated/0/dnscrypt-proxy"
BLOCKLIST="$DNSCRYPT_DIR/blocked-names.txt"
# Was misspelled "gustum-blocked-names.txt" in every release up to
# r8. The name is user-facing - people type the obvious spelling,
# their file is never read, and nothing tells them why. Renamed, with
# the old name still honoured (and migrated on install by
# customize.sh) so nobody's existing list silently stops working.
CUSTOM="$DNSCRYPT_DIR/custom-blocked-names.txt"
CUSTOM_LEGACY="$DNSCRYPT_DIR/gustum-blocked-names.txt"
if [ ! -f "$CUSTOM" ] && [ -f "$CUSTOM_LEGACY" ]; then
  mv -f "$CUSTOM_LEGACY" "$CUSTOM" 2>/dev/null && \
    echo "* Renamed gustum-blocked-names.txt -> custom-blocked-names.txt"
fi
LAST_UPDATE_FILE="$DNSCRYPT_DIR/.last_update"
TMP="$DNSCRYPT_DIR/blocklist.tmp"
LOG="/data/adb/dnscrypt-proxy.log"
URL_1="https://big.oisd.nl/domainswild2"
URL_2="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.plus-onlydomains.txt"
URL_3="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/ultimate-onlydomains.txt"
UPDATE_FLAG="$DNSCRYPT_DIR/.update_ok"

# -----------------------------------------------
# Cleanup trap - runs on exit, interrupt or kill
# -----------------------------------------------
cleanup() {
  kill $CURL_PID 2>/dev/null
  rm -f "$TMP" 2>/dev/null
  [ ! -f "$UPDATE_FLAG" ] && rm -f "${BLOCKLIST}.new" 2>/dev/null
  rm -f "$UPDATE_FLAG" 2>/dev/null
}
trap cleanup EXIT INT TERM

# -----------------------------------------------
# Progress bar helper
# SukiSU terminal does not support \r overwrites,
# so we print a new line only when % actually changes
# -----------------------------------------------
progress_bar() {
  local current=$1
  local total=$2
  local width=38
  [ "$total" -eq 0 ] && total=1
  local pct=$(( current * 100 / total ))
  [ "$pct" -gt 99 ] && pct=99
  local filled=$(( pct * width / 100 ))
  local bar="" i=0
  while [ $i -lt $filled ]; do bar="${bar}█"; i=$(( i + 1 )); done
  while [ $i -lt $width  ]; do bar="${bar}░"; i=$(( i + 1 )); done
  echo "  [${bar}] ${pct}%"
}

echo " "
echo "************************************"
echo "*   DNSCrypt Blocklist Updater     *"
echo "*        OISD Big List             *"
echo "************************************"
echo " "

# -----------------------------------------------
# Check storage is accessible
# -----------------------------------------------
if [ ! -d "$DNSCRYPT_DIR" ]; then
  echo "! ERROR: DNSCrypt directory not found!"
  echo "! Path: $DNSCRYPT_DIR"
  echo "! Is the module installed and rebooted?"
  exit 1
fi

# -----------------------------------------------
# Count existing domains before anything
# -----------------------------------------------
OLD_COUNT=0
if [ -f "$BLOCKLIST" ]; then
  OLD_COUNT=$(wc -l < "$BLOCKLIST" 2>/dev/null || echo 0)
fi

echo "-----------------------------------------------"
echo "  Current blocklist: $OLD_COUNT domains"
echo "-----------------------------------------------"
echo " "

# -----------------------------------------------
# Get Content-Length for accurate progress bar
# Falls back to 20MB if HEAD fails
# -----------------------------------------------
get_expected() {
  local url="$1"
  local len
  len=$(curl -sI --max-time 10 --connect-timeout 8 "$url" 2>/dev/null \
        | grep -i "^content-length:" | tail -1 \
        | tr -d '[:space:]\r' | cut -d: -f2)
  echo "$len" | grep -qE '^[0-9]+$' && [ "$len" -gt 0 ] \
    && echo "$len" || echo "20971520"
}

# -----------------------------------------------
# Download with fallback sources
# 1. OISD Big  2. hagezi pro.plus  3. hagezi ultimate
# -----------------------------------------------
download_list() {
  local url="$1"
  local label="$2"
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
      # Print only on every 5% change to reduce output lines
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
  local ret=$?
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

# -----------------------------------------------
# Merge: strip comments + empty lines, then combine
# existing blocked-names.txt + new download,
# sort, remove duplicates
# -----------------------------------------------
echo "-----------------------------------------------"
echo "* Step 1/2 - Cleaning downloaded list..."
echo "-----------------------------------------------"
sed -i '/^#/d;/^$/d' "$TMP"
# Add *. prefix to lines that don't already have it
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
  # Normalize custom entries to the same *. wildcard format as the
  # downloaded list, so entries typed without the prefix still block
  # subdomains consistently instead of silently mismatching at runtime.
  CUSTOM_NORM="$DNSCRYPT_DIR/custom.tmp"
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

# -----------------------------------------------
# Replace blocklist atomically
# -----------------------------------------------
NEW_COUNT=$(wc -l < "${BLOCKLIST}.new" 2>/dev/null || echo 0)
ADDED=$(( NEW_COUNT - OLD_COUNT ))

# 1000 is a sanity floor well below any real OISD/hagezi pull (which run
# in the hundreds of thousands) - it only catches "basically nothing was
# in the download" (truncated fetch, malformed upstream format, etc).
# ">0" used to be the only guard here, which let a handful of garbage
# lines silently overwrite a working blocklist of hundreds of thousands
# of entries.
MIN_SANE_COUNT=1000

if [ "$NEW_COUNT" -ge "$MIN_SANE_COUNT" ]; then
  mv "${BLOCKLIST}.new" "$BLOCKLIST"
  touch "$UPDATE_FLAG"
  # Write exact timestamp of this update
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
       grep -qi "14EA" /proc/net/udp 2>/dev/null; then
      echo "* dnscrypt-proxy reloaded successfully — no downtime!"
      break
    fi
    sleep 1
    WAIT=$((WAIT + 1))
  done

  if [ "$WAIT" -ge 15 ]; then
    echo "* dnscrypt-proxy will restart via watchdog shortly."
  fi

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