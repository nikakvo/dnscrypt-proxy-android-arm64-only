ui_print " "
ui_print "******************************"
ui_print "*   dnscrypt-proxy-android   *"
ui_print "*        Аrm64 ONLY          *"
ui_print "*          2.1.18-r10         *"
ui_print "******************************"
ui_print "*        Tears Burn          *"
ui_print "******************************"
ui_print " "

# -----------------------------------------------
# Volume key helper
# Returns 0 if Volume UP pressed, 1 if Volume DOWN
# Default (timeout / no input) = DOWN (abort)
# -----------------------------------------------
choose_key() {
  ui_print "   VOL UP   = Yes / Continue"
  ui_print "   VOL DOWN = No  / Abort"
  ui_print "   (30 seconds to respond)"
  ui_print " "

  local KEYCHECK="$TMPDIR/keycheck"
  rm -f "$KEYCHECK"

  # -----------------------------------------------
  # Method 1: getevent without arguments
  # Listens to ALL input devices at once
  # Works on 95% of devices/environments
  # -----------------------------------------------
  if command -v getevent >/dev/null 2>&1; then
    (getevent -lq 2>/dev/null | while IFS= read -r line; do
      case "$line" in
        *KEY_VOLUMEUP*DOWN*)
          echo "up" > "$KEYCHECK"; break ;;
        *KEY_VOLUMEDOWN*DOWN*)
          echo "down" > "$KEYCHECK"; break ;;
      esac
    done) &
    GETEVENT_PID=$!

    # Manual 30s timeout loop (no 'timeout' command needed)
    i=0
    while [ $i -lt 30 ]; do
      [ -f "$KEYCHECK" ] && break
      sleep 1
      i=$((i + 1))
    done
    kill $GETEVENT_PID 2>/dev/null
    wait $GETEVENT_PID 2>/dev/null
  fi

  # -----------------------------------------------
  # Method 2: /dev/input/event* directly (fallback)
  # Used when Method 1 produced no result
  # Iterates each input device individually
  # -----------------------------------------------
  if [ ! -f "$KEYCHECK" ] && [ -d /dev/input ]; then
    ui_print "   (trying fallback input method...)"

    for dev in /dev/input/event*; do
      [ -c "$dev" ] || continue
      (getevent -lq "$dev" 2>/dev/null | while IFS= read -r line; do
        case "$line" in
          *KEY_VOLUMEUP*DOWN*)
            echo "up" > "$KEYCHECK"; break ;;
          *KEY_VOLUMEDOWN*DOWN*)
            echo "down" > "$KEYCHECK"; break ;;
        esac
      done) &
    done

    # Manual 30s timeout loop for fallback
    i=0
    while [ $i -lt 30 ]; do
      [ -f "$KEYCHECK" ] && break
      sleep 1
      i=$((i + 1))
    done
    # Kill all remaining getevent processes
    # Use pkill -P to only kill children of this script,
    # not any unrelated getevent process (e.g. from Termux)
    pkill -P $$ 2>/dev/null
  fi

  local RESULT
  RESULT=$(cat "$KEYCHECK" 2>/dev/null)
  rm -f "$KEYCHECK"

  # Default = DOWN (abort) if no input detected
  # Never remove anything without explicit confirmation
  if [ "$RESULT" = "up" ]; then
    return 0
  else
    return 1
  fi
}

MODDIR_ROOT="/data/adb/modules"

# ===============================================
# STEP 2: CONFLICT DETECTION
# ===============================================
ui_print "-----------------------------------------------"
ui_print "* Scanning for conflicting modules and apps..."
ui_print "-----------------------------------------------"
ui_print " "

CONFLICT_MODULES_INFO=""
CONFLICT_MODULES_DIRS=""
CONFLICT_APKS_INFO=""
CONFLICT_APKS_LIST=""

# -----------------------------------------------
# Scan installed modules via module.prop
# -----------------------------------------------
CONFLICT_MOD_KEYWORDS="adaway bindhosts energized systemlesshosts \
dns66 invizible nextdns rethinkdns cloudflared smartdns dnsmasq \
adguard personaldnsfilter blokada nebulo controld"

for dir in "$MODDIR_ROOT"/*/; do
  [ -f "${dir}module.prop" ] || continue
  [ -f "${dir}disable" ]     && continue

  MOD_ID=$(grep   '^id='   "${dir}module.prop" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
  MOD_NAME=$(grep '^name=' "${dir}module.prop" 2>/dev/null | cut -d= -f2)

  # Skip ourselves
  case "$MOD_ID" in *dnscrypt*|*dnscrypt_proxy*) continue ;; esac

  MOD_ID_LOWER=$(echo "$MOD_ID"   | tr '[:upper:]' '[:lower:]')
  MOD_NM_LOWER=$(echo "$MOD_NAME" | tr '[:upper:]' '[:lower:]')

  for KW in $CONFLICT_MOD_KEYWORDS; do
    case "${MOD_ID_LOWER} ${MOD_NM_LOWER}" in
      *"$KW"*)
        DISPLAY="${MOD_NAME:-$MOD_ID} (id: $MOD_ID)"
        CONFLICT_MODULES_INFO="${CONFLICT_MODULES_INFO}  [MODULE] ${DISPLAY}\n"
        CONFLICT_MODULES_DIRS="${CONFLICT_MODULES_DIRS} ${dir}"
        break
        ;;
    esac
  done
done

# -----------------------------------------------
# Scan installed APKs
# -----------------------------------------------
CONFLICT_PKG_LIST="\
org.adaway \
org.blokada.alarm \
org.blokada.origin.alarm \
com.blokada.slim \
dnsfilter.android \
com.frostnerd.smokescreen \
com.controld.app \
com.nextdns.nextdns \
com.celzero.bravedns \
org.gnu.icecat \
com.rethinkdns.rethink \
de.measite.minidns \
ru.blockada.app"

for PKG in $CONFLICT_PKG_LIST; do
  if pm list packages 2>/dev/null | grep -q "^package:${PKG}$"; then
    CONFLICT_APKS_INFO="${CONFLICT_APKS_INFO}  [APK]    ${PKG}\n"
    CONFLICT_APKS_LIST="${CONFLICT_APKS_LIST} ${PKG}"
  fi
done

# -----------------------------------------------
# Check for running conflicting processes
# -----------------------------------------------
CONFLICT_PROCS_INFO=""
for PROC in dnsmasq smartdns cloudflared adguard; do
  if pgrep -f "$PROC" >/dev/null 2>&1; then
    CONFLICT_PROCS_INFO="${CONFLICT_PROCS_INFO}  [PROC]   ${PROC} (currently running)\n"
  fi
done

# -----------------------------------------------
# Evaluate and act on conflicts
# -----------------------------------------------
ALL_CONFLICTS="${CONFLICT_MODULES_INFO}${CONFLICT_APKS_INFO}${CONFLICT_PROCS_INFO}"

if [ -n "$(printf '%b' "$ALL_CONFLICTS" | tr -d '[:space:]')" ]; then

  ui_print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  ui_print "!  CONFLICTS DETECTED - Action required!     !"
  ui_print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  ui_print " "
  ui_print "  The following conflicting modules/apps"
  ui_print "  were found on your device:"
  ui_print " "
  printf '%b' "$ALL_CONFLICTS" | while IFS= read -r line; do
    [ -n "$line" ] && ui_print "$line"
  done
  ui_print " "
  ui_print "  These WILL conflict with dnscrypt-proxy"
  ui_print "  (DNS port 53 / hosts file conflicts)."
  ui_print " "
  ui_print "-----------------------------------------------"
  ui_print "  Remove ALL listed conflicts and continue?"
  ui_print "-----------------------------------------------"
  ui_print " "

  if choose_key; then
    ui_print "* Removing conflicting modules and apps..."
    ui_print " "

    # Mark conflicting modules for removal
    for dir in $CONFLICT_MODULES_DIRS; do
      MOD_ID=$(grep '^id=' "${dir}module.prop" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
      ui_print "  * Disabling + marking for removal: $MOD_ID"
      touch "${dir}disable" 2>/dev/null
      touch "${dir}remove"  2>/dev/null
    done

    # Uninstall conflicting APKs
    for PKG in $CONFLICT_APKS_LIST; do
      ui_print "  * Uninstalling APK: $PKG"
      pm uninstall --user 0 "$PKG" >/dev/null 2>&1 || \
      pm uninstall          "$PKG" >/dev/null 2>&1
    done

    ui_print " "
    ui_print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    ui_print "!        IMPORTANT - READ CAREFULLY          !"
    ui_print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    ui_print " "
    ui_print "  Conflicting modules have been marked"
    ui_print "  for removal. They will be fully"
    ui_print "  deleted after a reboot."
    ui_print " "
    ui_print "  NEXT STEPS:"
    ui_print "  1. Close this installer"
    ui_print "  2. Reboot your device"
    ui_print "  3. Flash dnscrypt-proxy again"
    ui_print " "
    ui_print "  The installation will complete cleanly"
    ui_print "  on the second flash."
    ui_print " "
    abort "Reboot required. Flash again after reboot."

  else
    ui_print " "
    ui_print "* Aborted by user."
    ui_print "* Please resolve conflicts manually,"
    ui_print "* then flash dnscrypt-proxy again."
    ui_print " "
    abort "Installation aborted: conflicts not resolved."
  fi

else
  ui_print "* No conflicts detected."
  ui_print "* Proceeding with installation..."
  ui_print " "
fi

# ===============================================
# MAIN INSTALLATION
# Reached only when device is clean
# ===============================================

BINARY_PATH="$MODPATH/binary/dnscrypt-proxy-arm64"
CONFIG_PATH="$MODPATH/config"
DNSCRYPT_DIR="/storage/emulated/0/dnscrypt-proxy"
CONFIG_FILE="$DNSCRYPT_DIR/dnscrypt-proxy.toml"

# -----------------------------------------------
# Stop any running dnscrypt-proxy instance
# -----------------------------------------------
if pgrep -x dnscrypt-proxy >/dev/null 2>&1; then
  ui_print "* Stopping running dnscrypt-proxy instance."
  pkill -x dnscrypt-proxy 2>/dev/null
  sleep 1
fi

# -----------------------------------------------
# Create required paths
# -----------------------------------------------
ui_print "* Creating the binary path."
mkdir -p "$MODPATH/system/bin"

ui_print "* Creating the config path."
mkdir -p "$DNSCRYPT_DIR"

# -----------------------------------------------
# Copy binary
# -----------------------------------------------
if [ -f "$BINARY_PATH" ]; then
  ui_print "* Copying the binary file."
  cp -af "$BINARY_PATH" "$MODPATH/system/bin/dnscrypt-proxy"
else
  abort "arm64 binary is missing! This module supports arm64 only."
fi

# -----------------------------------------------
# Preserve user data — backup and replace config only
#
# We intentionally DO NOT rm -rf $DNSCRYPT_DIR.
# Destroying it wipes:
#   - blocked-names.txt  → blocklist update work is lost
#   - *.md cache files   → resolver list must re-download
#
# Strategy:
#   1. Backup existing toml via cp (safe for any content)
#   2. Remove only known config/cache files
#   3. Leave blocked-names.txt and .bak files alone
# -----------------------------------------------
mkdir -p "$DNSCRYPT_DIR"

if [ -f "$CONFIG_FILE" ]; then
  BACKUP_NAME="dnscrypt-proxy.toml-$(date +%d.%m.%Y-%H_%M).bak"
  ui_print "* Backing up existing config to: $BACKUP_NAME"
  cp -f "$CONFIG_FILE" "$DNSCRYPT_DIR/$BACKUP_NAME" 2>/dev/null
fi

# Remove only config/cache files — never touch blocked-names.txt or .bak files
ui_print "* Removing old config files (preserving logs and blocklist)."
rm -f "$DNSCRYPT_DIR/dnscrypt-proxy.toml"            2>/dev/null
rm -f "$DNSCRYPT_DIR/public-resolvers.md"            2>/dev/null
rm -f "$DNSCRYPT_DIR/public-resolvers.md.minisig"    2>/dev/null
rm -f "$DNSCRYPT_DIR/relays.md"                      2>/dev/null
rm -f "$DNSCRYPT_DIR/relays.md.minisig"              2>/dev/null
rm -f "$DNSCRYPT_DIR/allowed-names.txt"              2>/dev/null
rm -f "$DNSCRYPT_DIR/allowed-ips.txt"                2>/dev/null
rm -f "$DNSCRYPT_DIR/blocked-ips.txt"                2>/dev/null
# blocked-names.txt intentionally NOT removed — preserves user's blocklist

# -----------------------------------------------
# The cp -af below force-overwrites EVERYTHING from config/,
# including blocked-names.txt and custom-blocked-names.txt —
# which defeats the whole point of not rm'ing them above.
# Stash them aside first, restore after the template copy.
# -----------------------------------------------
[ -f "$DNSCRYPT_DIR/blocked-names.txt" ] && \
  mv -f "$DNSCRYPT_DIR/blocked-names.txt" "$DNSCRYPT_DIR/.blocked-names.txt.preserve" 2>/dev/null
# One-time rename of the long-standing misspelling. Done before the
# stash so the preserved file already carries the correct name.
if [ -f "$DNSCRYPT_DIR/gustum-blocked-names.txt" ] && [ ! -f "$DNSCRYPT_DIR/custom-blocked-names.txt" ]; then
  mv -f "$DNSCRYPT_DIR/gustum-blocked-names.txt" "$DNSCRYPT_DIR/custom-blocked-names.txt" 2>/dev/null
  ui_print "* Renamed gustum-blocked-names.txt -> custom-blocked-names.txt"
fi
[ -f "$DNSCRYPT_DIR/custom-blocked-names.txt" ] && \
  mv -f "$DNSCRYPT_DIR/custom-blocked-names.txt" "$DNSCRYPT_DIR/.custom-blocked-names.txt.preserve" 2>/dev/null

# -----------------------------------------------
# Copy fresh configuration files
# -----------------------------------------------
if [ -d "$CONFIG_PATH" ]; then
  ui_print "* Copying configuration files into the dnscrypt-proxy folder."
  cp -af "$CONFIG_PATH/." "$DNSCRYPT_DIR/"
else
  abort "Configuration file (.toml) is missing!"
fi

# Restore the user's actual blocklists over the shipped templates
if [ -f "$DNSCRYPT_DIR/.blocked-names.txt.preserve" ]; then
  mv -f "$DNSCRYPT_DIR/.blocked-names.txt.preserve" "$DNSCRYPT_DIR/blocked-names.txt"
  ui_print "* Restored existing blocked-names.txt (preserved across reflash)."
fi
if [ -f "$DNSCRYPT_DIR/.custom-blocked-names.txt.preserve" ]; then
  mv -f "$DNSCRYPT_DIR/.custom-blocked-names.txt.preserve" "$DNSCRYPT_DIR/custom-blocked-names.txt"
  ui_print "* Restored existing custom-blocked-names.txt (preserved across reflash)."
fi
# The shipped template still uses the old name; drop it so the folder
# does not end up with both spellings side by side.
rm -f "$DNSCRYPT_DIR/gustum-blocked-names.txt" 2>/dev/null

# -----------------------------------------------
# Permissions
# Files: 0644, dirs: 0755, executables set explicitly
# -----------------------------------------------
ui_print "* Setting permissions on binary."
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/system/bin/dnscrypt-proxy" 0 0 0755
set_perm "$MODPATH/service.sh"      0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh"    0 0 0755
set_perm "$MODPATH/update-blocklist.sh" 0 0 0755

# -----------------------------------------------
# Runtime verification: confirm binary is usable
# Tests the actual installed binary — ground truth
# for whether the environment will work post-reboot.
# -----------------------------------------------
ui_print "* Verifying installed binary..."
VERIFY_BIN="$MODPATH/system/bin/dnscrypt-proxy"
VERIFY_OK=0

if [ -f "$VERIFY_BIN" ] && [ -x "$VERIFY_BIN" ]; then
  # Try running the binary with -version flag
  # Expected: outputs version string and exits 0
  VERSION_OUT=$("$VERIFY_BIN" -version 2>&1)
  if echo "$VERSION_OUT" | grep -q "2\.[0-9]"; then
    ui_print "* Binary verified: $VERSION_OUT"
    VERIFY_OK=1
  else
    ui_print "* Binary present but -version returned unexpected output."
    ui_print "  Output: $VERSION_OUT"
  fi
else
  ui_print "* Binary not found or not executable at expected path."
fi

if [ "$VERIFY_OK" -eq 0 ]; then
  ui_print " "
  ui_print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  ui_print "!  WARNING: Binary verification failed!      !"
  ui_print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  ui_print " "
  ui_print "  The binary was installed but could not"
  ui_print "  be executed. This may indicate:"
  ui_print "    - SELinux policy blocking execution"
  ui_print "    - Mount namespace not working"
  ui_print "    - Incompatible binary for this device"
  ui_print " "
  ui_print "  The module is installed but may not"
  ui_print "  function correctly after reboot."
  ui_print " "
fi

# -----------------------------------------------
# Settings file, created once and never overwritten.
# Lives in /data/adb so it survives module updates - anything
# inside $MODPATH is replaced wholesale on every flash.
# -----------------------------------------------
CONF="/data/adb/dnscrypt-proxy-android.conf"
if [ ! -f "$CONF" ]; then
  cat > "$CONF" << 'CONFEOF'
# dnscrypt-proxy-android settings
# Edit, then reboot. This file is never overwritten by updates.

# Disable IPv6 entirely (kernel + sysctl + ip6tables).
# 1 = on (default). This is the module's leak-prevention core.
# It is applied at boot before the network exists, so it is
# unconditional there; service.sh lifts it automatically if the
# device turns out to be on an IPv6-only network, where blocking
# IPv6 would block all traffic including IPv4-over-IPv6 (464XLAT).
# Set to 0 to leave IPv6 alone entirely.
IPV6_KILL=1

# Drop outbound UDP/443 (QUIC).
# 1 = on (default). Stops Chrome/YouTube and similar from using
# QUIC's built-in DoH to bypass this proxy. Browsers fall back to
# TLS/TCP transparently; a few QUIC-only apps will not work.
# Set to 0 if you need HTTP/3.
QUIC_BLOCK=1
CONFEOF
  ui_print "* Created settings file: $CONF"
else
  ui_print "* Existing settings file kept: $CONF"
fi

# -----------------------------------------------
# Disable Android 9+ Private DNS
# -----------------------------------------------
ui_print "* Disabling Android 9+ Private DNS mode."
settings put global private_dns_mode off

# -----------------------------------------------
# Cleanup temporary binary folder from zip
# -----------------------------------------------
ui_print "* Cleaning up unnecessary files."
rm -rf "$MODPATH/binary"

ui_print " "
ui_print "* Done! DNSCrypt Proxy installed cleanly."
ui_print "* Reboot your device to activate."
ui_print " "
