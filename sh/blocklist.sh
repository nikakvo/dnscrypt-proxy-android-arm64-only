#!/system/bin/sh
# shellcheck shell=sh disable=SC2034
#
# sh/blocklist.sh - how blocked-names.txt is made.
#
# Sourced after sh/common.sh by ctl.sh, service.sh and update-blocklist.sh.
# Only defines things.
#
#   bl_update   download the selected sources, then bl_build
#   bl_build    assemble blocked-names.txt from the cached sources plus
#               custom-blocked-names.txt - offline, takes a few seconds
#
# Every source that downloads cleanly is kept in $BL_SRC_DIR. A source that
# fails next time falls back to that copy instead of silently vanishing
# from the list, and an edit to the custom list is applied by rebuilding
# from the cache - no download, and deletions just work.
#
# ── How dnscrypt-proxy reads a rule (pattern_matcher.go) ────────────────────
#   example.com      example.com and every subdomain  (suffix)
#   *.example.com    exactly the same as above - the leading "*." is dropped
#   =example.com     example.com only                 (exact)
#   ads.*            anything starting with "ads."    (prefix)
#   *sex*            anything containing "sex"        (substring)
#   ads[0-9].*.com   glob
#
# Up to r12 every rule got "*." glued to the front. For plain names that was
# a no-op, but it turned "=exact.com" into a broken rule and "ads.*" into
# "*.ads.*" - a substring match that blocks everything containing "ads.".
# Rules are now kept exactly as written; only the plain ones are
# canonicalised (lowercase, no "*." / "." prefix) so they can be deduped.

BL_SRC_DIR="$DATA_DIR/sources"
BL_CUSTOM="$DATA_DIR/custom-blocked-names.txt"
BL_CUSTOM_URLS="$DATA_DIR/custom-sources.txt"
BL_LOCK="$STATE_DIR/blocklist.lock"
BL_REBUILD_PENDING="$STATE_DIR/blocklist_rebuild_pending"
BL_LAST_EPOCH="$DATA_DIR/.last_update_epoch"
BL_LAST_ATTEMPT="$DATA_DIR/.last_update_attempt"
BL_REPORT="$DATA_DIR/.last_update_report"

# ── Catalog ──────────────────────────────────────────────────────────────────
# id|group|label|url|minimum entries|description
#
# The minimum is a sanity floor per source: a download that parses to fewer
# rules than this is an error page or a truncated file, not a list.
# Deliberately left out: HaGeZi TIF full (~1.5M entries, too much memory
# for a phone daemon), spam-tlds (blocks entire TLDs), and the DoH/VPN
# bypass list (it names the resolvers this module itself uses).
bl_catalog() {
  cat <<'EOF'
oisd-small|OISD|Small|https://small.oisd.nl/domainswild2|10000|Ads, trackers, malware. Lean, almost no false positives
oisd-big|OISD|Big|https://big.oisd.nl/domainswild2|50000|Broad ads, tracking and malware coverage. The default
oisd-nsfw-small|OISD|NSFW Small|https://nsfw-small.oisd.nl/domainswild2|1000|Adult content, compact
oisd-nsfw|OISD|NSFW|https://nsfw.oisd.nl/domainswild2|10000|Adult content, full
hagezi-light|HaGeZi|Light|https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/light-onlydomains.txt|10000|Basic protection, no restrictions
hagezi-normal|HaGeZi|Normal|https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/multi-onlydomains.txt|50000|All-round protection
hagezi-pro|HaGeZi|Pro|https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro-onlydomains.txt|50000|Extended protection
hagezi-proplus|HaGeZi|Pro++|https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.plus-onlydomains.txt|50000|Maximum protection, some breakage possible
hagezi-ultimate|HaGeZi|Ultimate|https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/ultimate-onlydomains.txt|50000|Aggressive, expect breakage
hagezi-tif-mini|HaGeZi|Threat Intel mini|https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/tif.mini-onlydomains.txt|10000|Malware, phishing, scams. Compact
hagezi-tif-medium|HaGeZi|Threat Intel medium|https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/tif.medium-onlydomains.txt|50000|Malware, phishing, scams. Large
hagezi-popupads|Add-ons|Pop-up ads|https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/popupads-onlydomains.txt|1000|Pop-up and pop-under ad networks
hagezi-fake|Add-ons|Fake & scam|https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/fake-onlydomains.txt|1000|Fake shops, scam and fraud sites
hagezi-gambling|Add-ons|Gambling|https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/gambling-onlydomains.txt|1000|Gambling and betting
hagezi-nsfw|Add-ons|NSFW (HaGeZi)|https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/nsfw-onlydomains.txt|1000|Adult content
hagezi-native-xiaomi|Add-ons|Xiaomi trackers|https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/native.xiaomi-onlydomains.txt|20|Xiaomi / MIUI / HyperOS telemetry
hagezi-native-samsung|Add-ons|Samsung trackers|https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/native.samsung-onlydomains.txt|20|Samsung telemetry
hagezi-native-tiktok|Add-ons|TikTok trackers|https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/native.tiktok-onlydomains.txt|20|TikTok telemetry
hagezi-urlshortener|Add-ons|URL shorteners|https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/urlshortener-onlydomains.txt|100|Link shorteners often used to hide malicious links
EOF
}

# User-added URLs: one per line in $BL_CUSTOM_URLS. The id is derived from
# the URL itself, so removing one never shifts the ids of the others.
bl_url_id() { printf 'url-%s' "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"; }

bl_custom_catalog() {
  [ -f "$BL_CUSTOM_URLS" ] || return 0
  while IFS= read -r _u || [ -n "$_u" ]; do
    _u=${_u%%[ 	]*}
    case "$_u" in https://*) : ;; *) continue ;; esac
    printf '%s|Custom|%s|%s|1|Added by you\n' "$(bl_url_id "$_u")" "$_u" "$_u"
  done < "$BL_CUSTOM_URLS"
  unset _u
}

BL_CAT=""
bl_all_sources() {
  [ -n "$BL_CAT" ] || BL_CAT=$(bl_catalog; bl_custom_catalog)
  printf '%s\n' "$BL_CAT"
}
bl_catalog_reset() { BL_CAT=""; }

# Field <n> of the catalog line for <id>; empty when the id is unknown.
bl_field() { # <id> <n>
  bl_all_sources | awk -F'|' -v id="$1" -v n="$2" '$1 == id { print $n; exit }'
}

# The selected ids on one line, space-separated (for the list header).
bl_selected_line() { bl_selected | tr '\n' ' ' | sed 's/ *$//'; }

bl_selected() { # prints the selected ids that exist, one per line
  printf '%s\n' "$BLOCKLIST_SOURCES" | tr ',' '\n' | while IFS= read -r _id; do
    [ -n "$_id" ] && [ -n "$(bl_field "$_id" 1)" ] && echo "$_id"
  done
}

# ── Normalisation ────────────────────────────────────────────────────────────
# Reads any list on stdin, writes one rule per line:
#   plain name       canonical: lowercase, no "*." / "." in front
#   anything else    as written (=exact, prefix*, *substring*, globs)
# Understands plain lists, hosts files ("0.0.0.0 name") and AdBlock
# ("||name^"). Strips comments, inline comments, CR line endings and blanks.
# allow_tld=0 drops single-label plain names ("zip", "top"): from a
# downloaded list that would block a whole TLD. The custom list may.
bl_normalize() { # <allow_tld 0|1>
  awk -v allow_tld="$1" '
    {
      sub(/\r$/, "")
      sub(/[ \t]*#.*$/, "")
      gsub(/^[ \t]+|[ \t]+$/, "")
      if ($0 == "") next
      if (NF >= 2) {
        if ($1 == "0.0.0.0" || $1 == "127.0.0.1" || $1 == "::" || $1 == "::1") { $0 = $2 } else next
      }
      if (substr($0, 1, 2) == "||" && substr($0, length($0), 1) == "^") { $0 = substr($0, 3, length($0) - 3) }
      $0 = tolower($0)
      if ($0 == "localhost" || $0 == "localhost.localdomain" || $0 == "0.0.0.0") next
      p = $0
      if (substr(p, 1, 2) == "*.") p = substr(p, 3)
      else if (substr(p, 1, 1) == ".") p = substr(p, 2)
      if (p ~ /^[a-z0-9_-]+(\.[a-z0-9_-]+)*$/) {
        if (!allow_tld && index(p, ".") == 0) next
        print p
      } else {
        # Keep only characters a rule can contain. Tested by deleting
        # them, which is portable where bracket escapes in awk are not.
        t = $0
        gsub(/[a-z0-9_.*=?-]/, "", t)
        gsub(/[][]/, "", t)
        if (t == "" && index($0, ".") + index($0, "*") > 0) print $0
      }
    }'
}

# Plain names only (stdin) -> the same set without names already covered by
# a parent: with "doubleclick.net" blocked, "ad.doubleclick.net" adds
# nothing, because a plain rule matches every subdomain anyway.
#
# Labels are reversed with a SPACE between them. Space sorts below every
# character a domain can contain, so a parent always sorts directly before
# all of its children ("net doubleclick" < "net doubleclick ad" <
# "net doubleclick-x"); with "." as separator "-" would sort in between and
# hide a child from its parent.
bl_prune() {
  awk -F. '{ s = $NF; for (i = NF - 1; i >= 1; i--) s = s " " $i; print s }' |
    LC_ALL=C sort -u |
    awk 'last != "" && index($0, last " ") == 1 { next } { print; last = $0 }' |
    awk -F' ' '{ s = $NF; for (i = NF - 1; i >= 1; i--) s = s "." $i; print s }'
}

bl_is_plain_filter() { grep -E '^[a-z0-9_-]+(\.[a-z0-9_-]+)*$'; }
bl_is_pattern_filter() { grep -vE '^[a-z0-9_-]+(\.[a-z0-9_-]+)*$'; }

# ── Lock ─────────────────────────────────────────────────────────────────────
# One builder at a time: the Update button, an automatic update and a
# custom-list rebuild from the watchdog must never write the file together.
bl_lock() {
  mkdir -p "$STATE_DIR"
  if mkdir "$BL_LOCK" 2>/dev/null; then
    echo $$ > "$BL_LOCK/pid"
    return 0
  fi
  _lp=$(cat "$BL_LOCK/pid" 2>/dev/null)
  if [ -n "$_lp" ] && [ -d "/proc/$_lp" ]; then unset _lp; return 1; fi
  # Holder is gone (killed, rebooted mid-build): take the lock over.
  rm -rf "$BL_LOCK"
  unset _lp
  mkdir "$BL_LOCK" 2>/dev/null || return 1
  echo $$ > "$BL_LOCK/pid"
}
bl_unlock() { [ "$(cat "$BL_LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$BL_LOCK"; }

# ── Migration from r12 and earlier ───────────────────────────────────────────
# Before the source cache existed, blocked-names.txt was the only copy of
# the downloaded list. Keep it as a stand-in "legacy" source, minus what the
# custom list contributed, so a custom-list rebuild before the first real
# update does not throw the downloaded domains away.
bl_migrate_legacy() {
  mkdir -p "$BL_SRC_DIR"
  [ -f "$BL_SRC_DIR/legacy.txt" ] && return 0
  ls "$BL_SRC_DIR"/*.txt >/dev/null 2>&1 && return 0
  [ -f "$BLOCKLIST" ] || return 0
  if [ -f "$DATA_DIR/.custom.merged" ]; then
    bl_normalize 1 < "$DATA_DIR/.custom.merged" | LC_ALL=C sort -u > "$BL_SRC_DIR/.old_custom"
    bl_normalize 0 < "$BLOCKLIST" | LC_ALL=C sort -u | LC_ALL=C comm -23 - "$BL_SRC_DIR/.old_custom" > "$BL_SRC_DIR/legacy.txt"
    rm -f "$BL_SRC_DIR/.old_custom"
  else
    bl_normalize 0 < "$BLOCKLIST" > "$BL_SRC_DIR/legacy.txt"
  fi
  echo "$(date '+%Y-%m-%d %H:%M:%S')|$(wc -l < "$BL_SRC_DIR/legacy.txt" | tr -d ' ')" > "$BL_SRC_DIR/legacy.meta"
  rm -f "$DATA_DIR/.custom.merged"
  log_info "blocklist: kept the pre-r13 list as a 'legacy' source until the first update"
}

# ── Build ────────────────────────────────────────────────────────────────────
# Assemble blocked-names.txt from the cached selected sources (falling back
# to the legacy stand-in for a selected source that was never downloaded)
# plus the custom list. Prints a summary; returns non-zero and leaves the
# live list alone on any failure.
bl_build() {
  mkdir -p "$BL_SRC_DIR"
  bl_migrate_legacy
  _w="$BL_SRC_DIR/.work"
  rm -rf "$_w"; mkdir -p "$_w"

  : > "$_w/all"
  _used=""
  _missing=0
  for _id in $(bl_selected); do
    if [ -s "$BL_SRC_DIR/$_id.txt" ]; then
      cat "$BL_SRC_DIR/$_id.txt" >> "$_w/all"
      _used="$_used $_id"
    else
      _missing=1
    fi
  done
  if [ "$_missing" -eq 1 ] && [ -s "$BL_SRC_DIR/legacy.txt" ]; then
    cat "$BL_SRC_DIR/legacy.txt" >> "$_w/all"
    _used="$_used legacy"
  fi

  _raw=$(wc -l < "$_w/all"); _raw=$((_raw + 0))

  _custom_n=0
  if [ -f "$BL_CUSTOM" ]; then
    bl_normalize 1 < "$BL_CUSTOM" > "$_w/custom"
    _custom_n=$(LC_ALL=C sort -u "$_w/custom" | wc -l); _custom_n=$((_custom_n + 0))
  else
    : > "$_w/custom"
  fi

  # Sources selected but none of them cached: that is a failure, keep the
  # current list. Nothing selected and an empty custom list is not - the
  # right list is then an empty one. r12 refused that too, so removing the
  # last custom rule with no sources selected never unblocked it.
  if [ "$_raw" -eq 0 ] && [ "$_custom_n" -eq 0 ] && [ -n "$(bl_selected)" ]; then
    rm -rf "$_w"
    echo "! Nothing to build: no source is cached and the custom list is empty."
    return 1
  fi

  cat "$_w/all" "$_w/custom" > "$_w/merged"
  bl_is_plain_filter < "$_w/merged" > "$_w/plain"
  bl_is_pattern_filter < "$_w/merged" | LC_ALL=C sort -u > "$_w/patterns"
  _uniq=$(LC_ALL=C sort -u "$_w/plain" | wc -l); _uniq=$((_uniq + 0))
  bl_prune < "$_w/plain" > "$_w/pruned"
  _final_plain=$(wc -l < "$_w/pruned"); _final_plain=$((_final_plain + 0))
  _patterns=$(wc -l < "$_w/patterns"); _patterns=$((_patterns + 0))
  _final=$((_final_plain + _patterns))

  # A plain list that pruned down to nothing, from input that had names,
  # means a broken awk or sort - never ship that.
  if [ "$_uniq" -gt 0 ] && [ "$_final_plain" -eq 0 ]; then
    rm -rf "$_w"
    echo "! Build produced an empty list from $_uniq names - keeping the current list."
    return 1
  fi

  {
    echo "# blocked-names.txt - generated by dnscrypt-proxy-android, do not edit."
    echo "# Add your own rules to custom-blocked-names.txt instead."
    echo "# Built: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Sources:${_used:- none} + custom"
    echo "# Selected: $(bl_selected_line)"
    echo "# Rules: $_final ($_final_plain names, $_patterns patterns)"
    cat "$_w/pruned" "$_w/patterns"
  } > "$BLOCKLIST.new" && mv -f "$BLOCKLIST.new" "$BLOCKLIST" || {
    rm -f "$BLOCKLIST.new"; rm -rf "$_w"
    echo "! Could not write $BLOCKLIST (disk full?) - keeping the current list."
    return 1
  }
  rm -rf "$_w"

  echo "  Source rules : $_raw"
  echo "  Custom rules : $_custom_n"
  echo "  Unique names : $_uniq"
  echo "  Redundant    : $((_uniq - _final_plain)) subdomains of blocked parents removed"
  echo "  Final        : $_final rules"
  BL_FINAL=$_final
  BL_USED=$(echo $_used)
  unset _w _used _missing _id _raw _custom_n _uniq _final_plain _patterns _final
  return 0
}

# ── Download ─────────────────────────────────────────────────────────────────
bl_fetch() { # <url> <out>
  if command -v curl >/dev/null 2>&1; then
    curl -sfL --max-time 300 --connect-timeout 15 --retry 1 "$1" -o "$2" 2>/dev/null && return 0
  fi
  if [ -n "$BB" ]; then
    "$BB" wget -q -T 60 -O "$2" "$1" 2>/dev/null && return 0
  fi
  return 1
}

bl_content_length() { # <url>
  command -v curl >/dev/null 2>&1 || { echo 0; return; }
  _len=$(curl -sIL --max-time 10 --connect-timeout 8 "$1" 2>/dev/null |
    grep -i '^content-length:' | tail -n 1 | tr -dc '0-9')
  echo "${_len:-0}"
  unset _len
}

bl_progress() { # <bytes> <expected>
  [ "$2" -gt 0 ] || { printf '  %s KB\n' "$(( $1 / 1024 ))"; return; }
  _pct=$(( $1 * 100 / $2 )); [ "$_pct" -gt 100 ] && _pct=100
  _f=$(( _pct * 30 / 100 )); _bar=""; _i=0
  while [ "$_i" -lt 30 ]; do
    if [ "$_i" -lt "$_f" ]; then _bar="${_bar}█"; else _bar="${_bar}░"; fi
    _i=$((_i + 1))
  done
  printf '  [%s] %3d%%\n' "$_bar" "$_pct"
  unset _pct _f _bar _i
}

# Download one source into the cache. Returns 0 on a fresh copy.
bl_download_one() { # <id>
  _did=$1
  _durl=$(bl_field "$_did" 4)
  _dmin=$(bl_field "$_did" 5); _dmin=$((_dmin + 0))
  _dtmp="$BL_SRC_DIR/.$_did.download"
  rm -f "$_dtmp"

  _dexp=$(bl_content_length "$_durl"); _dexp=$((_dexp + 0))
  bl_fetch "$_durl" "$_dtmp" &
  _dfp=$!
  _dlast=-1
  while kill -0 "$_dfp" 2>/dev/null; do
    sleep 1
    _dsz=$(stat -c %s "$_dtmp" 2>/dev/null); _dsz=$((_dsz + 0))
    if [ "$_dexp" -gt 0 ]; then _dstep=$(( _dsz * 10 / _dexp )); else _dstep=$(( _dsz / 1048576 )); fi
    if [ "$_dstep" -ne "$_dlast" ]; then bl_progress "$_dsz" "$_dexp"; _dlast=$_dstep; fi
  done
  wait "$_dfp"; _drc=$?

  BL_DL_REASON=""
  if [ "$_drc" -ne 0 ] || [ ! -s "$_dtmp" ]; then
    BL_DL_REASON="download failed"
  elif head -c 512 "$_dtmp" | grep -qiE '<html|<!doctype'; then
    BL_DL_REASON="got a web page, not a list"
  else
    bl_normalize 0 < "$_dtmp" > "$_dtmp.norm"
    _dn=$(wc -l < "$_dtmp.norm"); _dn=$((_dn + 0))
    if [ "$_dn" -lt "$_dmin" ]; then
      BL_DL_REASON="only $_dn rules (expected at least $_dmin)"
    else
      mv -f "$_dtmp.norm" "$BL_SRC_DIR/$_did.txt"
      echo "$(date '+%Y-%m-%d %H:%M:%S')|$_dn" > "$BL_SRC_DIR/$_did.meta"
      BL_DL_COUNT=$_dn
    fi
  fi
  rm -f "$_dtmp" "$_dtmp.norm"
  unset _durl _dmin _dtmp _dexp _dfp _dlast _dsz _dstep _drc _dn
  [ -z "$BL_DL_REASON" ]
  _dr=$?
  unset _did
  return $_dr
}

# ── Update ───────────────────────────────────────────────────────────────────
# Download every selected source, then build. Writes a per-source report
# to $BL_REPORT (id|status|rules|note) for the WebUI.
bl_update() {
  if ! bl_lock; then
    echo "! Another blocklist job is running - try again in a moment."
    return 1
  fi
  mkdir -p "$BL_SRC_DIR"
  # Before anything is downloaded: once fresh copies land in the cache, the
  # migration can no longer tell that the old list was the only copy.
  bl_migrate_legacy
  date +%s > "$BL_LAST_ATTEMPT"
  : > "$BL_REPORT.tmp"

  _sel=$(bl_selected)
  if [ -z "$_sel" ]; then
    echo "* No sources selected - building from the custom list only."
  fi

  _fresh=0; _cached=0; _failed=0
  for _id in $_sel; do
    case "$(bl_field "$_id" 2)" in
      Add-ons) _label=$(bl_field "$_id" 3) ;;
      Custom)  _label="Your list: $(bl_field "$_id" 3)" ;;
      *)       _label="$(bl_field "$_id" 2) $(bl_field "$_id" 3)" ;;
    esac
    echo "-----------------------------------------------"
    echo "* $_label"
    if bl_download_one "$_id"; then
      echo "  OK - $BL_DL_COUNT rules"
      echo "$_id|ok|$BL_DL_COUNT|" >> "$BL_REPORT.tmp"
      _fresh=$((_fresh + 1))
    elif [ -s "$BL_SRC_DIR/$_id.txt" ]; then
      # "date|count" - IFS read: mksh treats a | inside ${x%%...} as alternation.
      _mdate=""; _mn=""
      [ -f "$BL_SRC_DIR/$_id.meta" ] && IFS='|' read -r _mdate _mn 2>/dev/null < "$BL_SRC_DIR/$_id.meta"
      echo "  ! $BL_DL_REASON - using the copy from ${_mdate:-an earlier update}"
      echo "$_id|cached|${_mn:-0}|$BL_DL_REASON" >> "$BL_REPORT.tmp"
      _cached=$((_cached + 1))
    else
      echo "  ! FAILED: $BL_DL_REASON - no earlier copy, skipped"
      echo "$_id|failed|0|$BL_DL_REASON" >> "$BL_REPORT.tmp"
      _failed=$((_failed + 1))
    fi
  done
  mv -f "$BL_REPORT.tmp" "$BL_REPORT"

  if [ -n "$_sel" ] && [ "$_fresh" -eq 0 ] && [ "$_cached" -eq 0 ]; then
    echo "-----------------------------------------------"
    echo "! ERROR: All sources failed - keeping the current list."
    echo "! Check the internet connection."
    log_warn "blocklist update: all sources failed, kept the current list"
    bl_unlock
    unset _sel _fresh _cached _failed _id _label _mdate _mn
    return 1
  fi

  # Sources that were deselected no longer need their cache.
  for _f in "$BL_SRC_DIR"/*.txt; do
    [ -f "$_f" ] || continue
    _id=$(basename "$_f" .txt)
    [ "$_id" = "legacy" ] && continue
    printf '%s\n' "$_sel" | grep -qx "$_id" || rm -f "$BL_SRC_DIR/$_id.txt" "$BL_SRC_DIR/$_id.meta"
  done
  # Once every selected source has a real copy, the stand-in has served.
  _all_real=1
  for _id in $_sel; do [ -s "$BL_SRC_DIR/$_id.txt" ] || _all_real=0; done
  [ "$_all_real" -eq 1 ] && rm -f "$BL_SRC_DIR/legacy.txt" "$BL_SRC_DIR/legacy.meta"

  if [ "$_all_real" -eq 0 ] && [ -s "$BL_SRC_DIR/legacy.txt" ]; then
    echo "-----------------------------------------------"
    echo "* A source has never downloaded - keeping the previous list in its place"
    echo "  so its domains stay blocked until it does."
  fi
  echo "-----------------------------------------------"
  echo "* Merging, deduplicating, adding custom-blocked-names.txt..."
  _old=$(blocklist_domains)
  if ! bl_build; then
    bl_unlock
    unset _sel _fresh _cached _failed _id _label _mdate _mn _f _all_real _old
    return 1
  fi
  bl_unlock

  date '+%Y-%m-%d %H:%M:%S' > "$LAST_UPDATE_FILE"
  date +%s > "$BL_LAST_EPOCH"
  echo "-----------------------------------------------"
  echo "  Sources: $_fresh fresh, $_cached from cache, $_failed failed"
  log_info "blocklist updated: $_old -> $BL_FINAL rules ($_fresh fresh, $_cached cached, $_failed failed)"
  unset _sel _fresh _cached _failed _id _label _mdate _mn _f _all_real _old
  return 0
}

# Offline rebuild after a custom-list edit. If another job holds the lock,
# leave a flag; the watchdog retries on its next pass.
#
# A long-running caller (the watchdog) loaded its settings at boot; the
# sources may have been changed in the WebUI since. Always build from what
# the settings file says NOW.
#
# Guard: if the rebuild uses the SAME sources as the list it replaces, only
# the custom list changed, and the result should be about the same size. A
# drop below half of a list with more than 10,000 rules then means a broken
# cache - refuse, keep the current list, say so. When the source selection
# itself changed since the last build (sources picked in the WebUI, no
# Update yet), a different size is expected and is not second-guessed.
bl_rebuild_custom() {
  if ! bl_lock; then
    : > "$BL_REBUILD_PENDING"
    return 2
  fi
  rm -f "$BL_REBUILD_PENDING"
  load_settings
  bl_catalog_reset
  _before=$(blocklist_domains); _before=$((_before + 0))
  # Compare SELECTIONS, not what ended up used: a selected source whose
  # cache broke drops out of "used", and that is exactly the case to catch.
  # A list from before r13 has no "# Selected:" line at all, and "no line"
  # must not read as "nothing was selected": with no sources selected now,
  # the two compared equal and the guard refused a legitimately empty list.
  if grep -q '^# Selected:' "$BLOCKLIST" 2>/dev/null; then
    _prev_src=$(sed -n 's/^# Selected: *//p' "$BLOCKLIST" 2>/dev/null | head -n 1)
  else
    _prev_src="(unknown)"
  fi
  cp -f "$BLOCKLIST" "$STATE_DIR/.blocklist.prev" 2>/dev/null
  bl_build > "$STATE_DIR/.rebuild.out" 2>&1
  _rc=$?
  if [ "$_rc" -eq 0 ] && [ "$_before" -gt 10000 ] && [ "$BL_FINAL" -lt $((_before / 2)) ] && \
     [ "$(bl_selected_line)" = "$_prev_src" ]; then
    mv -f "$STATE_DIR/.blocklist.prev" "$BLOCKLIST"
    log_warn "custom list rebuild would shrink the blocklist from $_before to $BL_FINAL rules - kept the current list. Run an Update from the WebUI to rebuild it from fresh sources."
    rm -f "$STATE_DIR/.rebuild.out"
    bl_unlock
    unset _before _prev_src
    return 1
  fi
  rm -f "$STATE_DIR/.blocklist.prev"
  unset _before _prev_src
  # (_rc is bl_build's result. r12 re-read $? here - the exit status of
  # `unset`, always 0 - so a failed rebuild was logged and reported as
  # applied and the caller reloaded for nothing.)
  bl_unlock
  if [ "$_rc" -eq 0 ]; then
    log_info "custom list applied: blocklist rebuilt from cache, $BL_FINAL rules"
  else
    log_warn "custom list rebuild failed: $(grep '^!' "$STATE_DIR/.rebuild.out" | head -n 1)"
  fi
  rm -f "$STATE_DIR/.rebuild.out"
  return $_rc
}
