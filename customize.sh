ui_print " "
ui_print "******************************"
ui_print "*   dnscrypt-proxy-android   *"
ui_print "*        Аrm64 ONLY          *"
ui_print "*        2.1.18-r11.6        *"
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

  KEYCHECK="$TMPDIR/keycheck"
  rm -f "$KEYCHECK"

  # -----------------------------------------------
  # Method 1: getevent without arguments
  # Listens to ALL input devices at once
  # -----------------------------------------------
  if command -v getevent >/dev/null 2>&1; then
    getevent -lq 2>/dev/null > "$TMPDIR/keyraw" &
    GETEVENT_PID=$!

    i=0
    while [ $i -lt 30 ]; do
      if grep -q "KEY_VOLUMEUP.*DOWN" "$TMPDIR/keyraw" 2>/dev/null; then
        echo "up" > "$KEYCHECK"; break
      fi
      if grep -q "KEY_VOLUMEDOWN.*DOWN" "$TMPDIR/keyraw" 2>/dev/null; then
        echo "down" > "$KEYCHECK"; break
      fi
      sleep 1
      i=$((i + 1))
    done

    # r10 killed the subshell wrapping the pipeline, not getevent
    # itself, so the process leaked and kept reading input devices for
    # the rest of the session. Kill the PID we actually started.
    kill "$GETEVENT_PID" 2>/dev/null
    kill -9 "$GETEVENT_PID" 2>/dev/null
    rm -f "$TMPDIR/keyraw"
  fi

  RESULT=$(cat "$KEYCHECK" 2>/dev/null)
  rm -f "$KEYCHECK"

  # Default = DOWN (abort) if no input detected.
  # Never remove anything without explicit confirmation.
  [ "$RESULT" = "up" ] && return 0
  return 1
}

MODDIR_ROOT="/data/adb/modules"

# ===============================================
# STEP 1: CONFLICT DETECTION
# ===============================================
ui_print "-----------------------------------------------"
ui_print "* Scanning for conflicting modules and apps..."
ui_print "-----------------------------------------------"
ui_print " "

CONFLICT_MODULES_INFO=""
CONFLICT_MODULES_DIRS=""
CONFLICT_APKS_INFO=""
CONFLICT_APKS_LIST=""

CONFLICT_MOD_KEYWORDS="adaway bindhosts energized systemlesshosts \
dns66 invizible nextdns rethinkdns cloudflared smartdns dnsmasq \
adguard personaldnsfilter blokada nebulo controld"

for dir in "$MODDIR_ROOT"/*/; do
  [ -f "${dir}module.prop" ] || continue
  [ -f "${dir}disable" ]     && continue

  MOD_ID=$(grep   '^id='   "${dir}module.prop" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
  MOD_NAME=$(grep '^name=' "${dir}module.prop" 2>/dev/null | cut -d= -f2)

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
com.rethinkdns.rethink \
de.measite.minidns \
ru.blockada.app"

for PKG in $CONFLICT_PKG_LIST; do
  if pm list packages 2>/dev/null | grep -q "^package:${PKG}$"; then
    CONFLICT_APKS_INFO="${CONFLICT_APKS_INFO}  [APK]    ${PKG}\n"
    CONFLICT_APKS_LIST="${CONFLICT_APKS_LIST} ${PKG}"
  fi
done

CONFLICT_PROCS_INFO=""
for PROC in dnsmasq smartdns cloudflared adguard; do
  if pgrep -f "$PROC" >/dev/null 2>&1; then
    CONFLICT_PROCS_INFO="${CONFLICT_PROCS_INFO}  [PROC]   ${PROC} (currently running)\n"
  fi
done

ALL_CONFLICTS="${CONFLICT_MODULES_INFO}${CONFLICT_APKS_INFO}${CONFLICT_PROCS_INFO}"

if [ -n "$(printf '%b' "$ALL_CONFLICTS" | tr -d '[:space:]')" ]; then

  ui_print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  ui_print "!  CONFLICTS DETECTED - Action required!     !"
  ui_print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
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

    for dir in $CONFLICT_MODULES_DIRS; do
      MOD_ID=$(grep '^id=' "${dir}module.prop" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
      ui_print "  * Disabling + marking for removal: $MOD_ID"
      touch "${dir}disable" 2>/dev/null
      touch "${dir}remove"  2>/dev/null
    done

    for PKG in $CONFLICT_APKS_LIST; do
      ui_print "  * Uninstalling APK: $PKG"
      pm uninstall --user 0 "$PKG" >/dev/null 2>&1 || \
      pm uninstall          "$PKG" >/dev/null 2>&1
    done

    ui_print " "
    ui_print "  NEXT STEPS:"
    ui_print "  1. Close this installer"
    ui_print "  2. Reboot your device"
    ui_print "  3. Flash dnscrypt-proxy again"
    ui_print " "
    abort "Reboot required. Flash again after reboot."
  else
    ui_print " "
    ui_print "* Aborted by user."
    abort "Installation aborted: conflicts not resolved."
  fi
else
  ui_print "* No conflicts detected."
  ui_print " "
fi

# ===============================================
# MAIN INSTALLATION
# ===============================================
#
# PATH CHANGE IN r11 - this is the important one.
#
# Everything the daemon reads now lives in /data/adb/dnscrypt-proxy.
# It used to live on /storage/emulated/0, which is FUSE: it mounts
# late, it is not visible in every mount namespace, and on an FBE
# device it does not exist at all until the first unlock. A daemon
# that starts at post-fs-data and reads its config from there is
# racing the storage stack on every single boot, and when it loses
# the race the DNS redirect is already installed with nothing behind
# it. That is the "no internet until I reflash" case.
#
# /data/adb is available before any of this matters.
#
# The sdcard folder stays, as the place you edit things. service.sh
# copies the small user-editable files inward whenever their mtime
# changes, so editing dnscrypt-proxy.toml there still works and takes
# effect within a minute, without a reboot.
# ===============================================

BINARY_PATH="$MODPATH/binary/dnscrypt-proxy-arm64"
CONFIG_PATH="$MODPATH/config"
DATA_DIR="/data/adb/dnscrypt-proxy"
SD_DIR="/storage/emulated/0/dnscrypt-proxy"
CONFIG_FILE="$DATA_DIR/dnscrypt-proxy.toml"
SYNC_FILES="dnscrypt-proxy.toml custom-blocked-names.txt allowed-names.txt allowed-ips.txt blocked-ips.txt"

if pgrep -x dnscrypt-proxy >/dev/null 2>&1; then
  ui_print "* Stopping running dnscrypt-proxy instance."
  pkill -x dnscrypt-proxy 2>/dev/null
  sleep 1
fi

ui_print "* Creating the binary path."
mkdir -p "$MODPATH/system/bin"

ui_print "* Creating the runtime path: $DATA_DIR"
mkdir -p "$DATA_DIR"
mkdir -p "$SD_DIR"

if [ -f "$BINARY_PATH" ]; then
  ui_print "* Copying the binary file."
  cp -af "$BINARY_PATH" "$MODPATH/system/bin/dnscrypt-proxy"
else
  abort "arm64 binary is missing! This module supports arm64 only."
fi

# -----------------------------------------------
# One-time migration from the old sdcard layout.
# Keeps the two files that represent real user work: the downloaded
# blocklist and the hand-written custom list. Everything else is
# regenerated from the module.
# -----------------------------------------------
for OLD in "$SD_DIR" /sdcard/dnscrypt-proxy /data/media/0/dnscrypt-proxy; do
  [ -d "$OLD" ] || continue
  if [ -f "$OLD/blocked-names.txt" ] && [ ! -f "$DATA_DIR/blocked-names.txt" ]; then
    ui_print "* Migrating blocked-names.txt from $OLD"
    cp -f "$OLD/blocked-names.txt" "$DATA_DIR/blocked-names.txt" 2>/dev/null
  fi
  # The name was misspelled "gustum-blocked-names.txt" up to r8.
  if [ -f "$OLD/gustum-blocked-names.txt" ] && [ ! -f "$OLD/custom-blocked-names.txt" ]; then
    mv -f "$OLD/gustum-blocked-names.txt" "$OLD/custom-blocked-names.txt" 2>/dev/null
    ui_print "* Renamed gustum-blocked-names.txt -> custom-blocked-names.txt"
  fi
  if [ -f "$OLD/custom-blocked-names.txt" ] && [ ! -f "$DATA_DIR/custom-blocked-names.txt" ]; then
    ui_print "* Migrating custom-blocked-names.txt from $OLD"
    cp -f "$OLD/custom-blocked-names.txt" "$DATA_DIR/custom-blocked-names.txt" 2>/dev/null
  fi
done

# -----------------------------------------------
# Back up the existing config, then refresh everything the module
# owns. Note cp -f, not cp -af: -a preserves timestamps, which meant
# every reflash reinstalled public-resolvers.md still dated December
# 2025 and the freshly installed cache was already months stale.
# -----------------------------------------------
if [ -f "$CONFIG_FILE" ]; then
  BACKUP_NAME="dnscrypt-proxy.toml-$(date +%d.%m.%Y-%H_%M).bak"
  ui_print "* Backing up existing config to: $BACKUP_NAME"
  cp -f "$CONFIG_FILE" "$DATA_DIR/$BACKUP_NAME" 2>/dev/null
fi

# Stash the user's real lists so the template copy cannot flatten them
[ -f "$DATA_DIR/blocked-names.txt" ] && \
  mv -f "$DATA_DIR/blocked-names.txt" "$DATA_DIR/.blocked-names.preserve" 2>/dev/null
[ -f "$DATA_DIR/custom-blocked-names.txt" ] && \
  mv -f "$DATA_DIR/custom-blocked-names.txt" "$DATA_DIR/.custom-blocked-names.preserve" 2>/dev/null

if [ -d "$CONFIG_PATH" ]; then
  ui_print "* Installing configuration into $DATA_DIR"
  for f in "$CONFIG_PATH"/*; do
    [ -f "$f" ] || continue
    cp -f "$f" "$DATA_DIR/" 2>/dev/null
  done
else
  abort "Configuration file (.toml) is missing!"
fi

if [ -f "$DATA_DIR/.blocked-names.preserve" ]; then
  mv -f "$DATA_DIR/.blocked-names.preserve" "$DATA_DIR/blocked-names.txt"
  ui_print "* Restored your existing blocked-names.txt"
fi
if [ -f "$DATA_DIR/.custom-blocked-names.preserve" ]; then
  mv -f "$DATA_DIR/.custom-blocked-names.preserve" "$DATA_DIR/custom-blocked-names.txt"
  ui_print "* Restored your existing custom-blocked-names.txt"
fi
rm -f "$DATA_DIR/gustum-blocked-names.txt" 2>/dev/null

# -----------------------------------------------
# Mirror the small editable files out to the sdcard so they can still
# be edited with a normal file manager. The big generated blocklist
# stays on /data - copying 7.6 MB across FUSE on every install, for a
# file nobody edits by hand, is pure cost.
# -----------------------------------------------
ui_print "* Mirroring editable files to $SD_DIR"
for f in $SYNC_FILES; do
  [ -f "$DATA_DIR/$f" ] && cp -f "$DATA_DIR/$f" "$SD_DIR/$f" 2>/dev/null
done
# Make the /data copies unambiguously the newest, so the first sync pass
# after boot does not mistake the mirror for a user edit and restart the
# daemon for nothing.
find "$DATA_DIR" -maxdepth 1 -type f -exec touch {} \; 2>/dev/null

cat > "$SD_DIR/READ-ME-FIRST.txt" << 'SDEOF'
This folder is a MIRROR for editing.

The files dnscrypt-proxy actually reads live in:
    /data/adb/dnscrypt-proxy/

Edit the files here; the module copies any changed file into the real
location within about a minute. Changing dnscrypt-proxy.toml restarts
the daemon, changing a list file reloads it without downtime.

Why the move: /storage/emulated/0 is FUSE. It mounts late, it is not
visible to every process at boot, and on an encrypted device it does
not exist at all until you first unlock the phone. Running the daemon
off it meant racing the storage stack on every boot - and when the
race was lost, the DNS redirect was already installed with nothing
listening behind it. That is what caused "no internet until I reflash".

blocked-names.txt is not mirrored here - it is 7.6 MB and generated by
the Update Blocklist button. Look for it in /data/adb/dnscrypt-proxy/.
SDEOF

# -----------------------------------------------
# Permissions
# -----------------------------------------------
ui_print "* Setting permissions."
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/system/bin/dnscrypt-proxy" 0 0 0755
set_perm "$MODPATH/service.sh"          0 0 0755
set_perm "$MODPATH/post-fs-data.sh"     0 0 0755
set_perm "$MODPATH/uninstall.sh"        0 0 0755
set_perm "$MODPATH/update-blocklist.sh" 0 0 0755
set_perm "$MODPATH/rules.sh"            0 0 0755
set_perm "$MODPATH/webroot/cgi-bin/status.sh" 0 0 0755
set_perm "$MODPATH/webroot/cgi-bin/log.sh"    0 0 0755
set_perm "$MODPATH/webroot/cgi-bin/update.sh" 0 0 0755
chmod 0700 "$DATA_DIR" 2>/dev/null
chown 0:0  "$DATA_DIR" 2>/dev/null

# -----------------------------------------------
# Runtime verification
# -----------------------------------------------
ui_print "* Verifying installed binary..."
VERIFY_BIN="$MODPATH/system/bin/dnscrypt-proxy"
VERIFY_OK=0

if [ -f "$VERIFY_BIN" ] && [ -x "$VERIFY_BIN" ]; then
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

# -----------------------------------------------
# Config sanity check: the installed toml must parse, or the daemon
# will never start and the redirect will sit there black-holing DNS
# until the failsafe fires. Better to know now, at flash time.
# -----------------------------------------------
if [ "$VERIFY_OK" -eq 1 ]; then
  ui_print "* Checking configuration..."
  CHECK_OUT=$(cd "$DATA_DIR" && "$VERIFY_BIN" -config "$CONFIG_FILE" -check 2>&1)
  if [ $? -eq 0 ]; then
    ui_print "* Configuration OK."
  else
    ui_print " "
    ui_print "!  WARNING: config check failed:"
    ui_print "   $CHECK_OUT"
    ui_print " "
  fi
fi

if [ "$VERIFY_OK" -eq 0 ]; then
  ui_print " "
  ui_print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  ui_print "!  WARNING: Binary verification failed!      !"
  ui_print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  ui_print " "
  ui_print "  Possible causes:"
  ui_print "    - SELinux policy blocking execution"
  ui_print "    - Mount namespace not working"
  ui_print "    - Incompatible binary for this device"
  ui_print " "
fi

# -----------------------------------------------
# Settings file, created once and never overwritten.
# -----------------------------------------------
CONF="/data/adb/dnscrypt-proxy-android.conf"
if [ ! -f "$CONF" ]; then
  cat > "$CONF" << 'CONFEOF'
# dnscrypt-proxy-android settings
# Edit, then reboot. This file is never overwritten by updates.

# Disable IPv6 entirely (ip6tables DROP policy + sysctl at boot).
# 1 = on (default). This is the module's leak-prevention core, and it
# stays on: nothing lifts it unless you say so with IPV6_AUTO_LIFT below.
# Set to 0 to leave IPv6 alone entirely.
IPV6_KILL=1

# Allow the module to switch the IPv6 killswitch OFF by itself if it
# decides the device is on an IPv6-only network.
# 0 = never (default). The killswitch stays on no matter what, which is
# the point of installing this module. If DNS is dead for another reason
# the module says so in the log and leaves the rules alone.
# 1 = allow it. Only turn this on if you actually use an IPv6-only
# carrier, where blocking IPv6 also blocks IPv4-over-IPv6 (464XLAT) and
# the phone would otherwise have no connectivity at all.
IPV6_AUTO_LIFT=0

# Keep forcing disable_ipv6 back to 1 on every network interface.
# 0 = no (default). IPv6 is stopped by the ip6tables DROP policy, which
# does not care what addresses exist on an interface, and apps never try
# IPv6 anyway because block_ipv6 in the toml means they get no AAAA
# records. On a phone the modem's PDN contexts (rmnet_dataN) re-enable
# IPv6 on a timer, so turning this on becomes an endless tug-of-war with
# the baseband that makes dnscrypt-proxy rotate its keys every minute for
# nothing - and it can break VoLTE/SMS where the IMS context is
# IPv6-only.
# 1 = yes, fight it anyway.
IPV6_PER_IFACE_ENFORCE=0

# How many lines of /data/adb/dnscrypt-proxy.log to keep. Rotation kicks
# in at twice this number. Default 1500, roughly half a day and about
# 350 KB: dnscrypt-proxy logs a two-line "Network change detected" pair
# about once a minute on devices whose modem keeps recreating its rmnet
# contexts, and a smaller budget evicts everything else within hours.
LOG_KEEP_LINES=1500

# Drop outbound UDP/443 (QUIC), on both IPv4 and IPv6.
# 1 = on (default). Stops Chrome/YouTube and similar from using
# QUIC's built-in DoH to bypass this proxy. Browsers fall back to
# TLS/TCP transparently; a few QUIC-only apps will not work.
# Set to 0 if you need HTTP/3.
QUIC_BLOCK=1
CONFEOF
  ui_print "* Created settings file: $CONF"
else
  ui_print "* Existing settings file kept: $CONF"
  # New keys are appended to an existing settings file rather than
  # rewriting it, so upgrades never clobber what the user has set.
  # The script defaults match these values, so behaviour is identical
  # either way - this only makes the option visible and editable.
  if ! grep -q '^IPV6_AUTO_LIFT=' "$CONF" 2>/dev/null; then
    cat >> "$CONF" << 'ADDEOF'

# Allow the module to switch the IPv6 killswitch OFF by itself if it
# decides the device is on an IPv6-only network.
# 0 = never (default). The killswitch stays on no matter what.
# 1 = allow it. Only for an IPv6-only carrier, where blocking IPv6 also
# blocks IPv4-over-IPv6 (464XLAT) and nothing would work otherwise.
IPV6_AUTO_LIFT=0
ADDEOF
    ui_print "* Added new setting IPV6_AUTO_LIFT=0 to $CONF"
  fi
  if ! grep -q '^IPV6_PER_IFACE_ENFORCE=' "$CONF" 2>/dev/null; then
    cat >> "$CONF" << 'ADD2EOF'

# Keep forcing disable_ipv6 back to 1 on every network interface.
# 0 = no (default). The ip6tables DROP policy is what stops IPv6; this
# only fights the modem's rmnet PDN contexts, which re-enable it on a
# timer, and can break VoLTE/SMS on IPv6-only IMS.
# 1 = yes, fight it anyway.
IPV6_PER_IFACE_ENFORCE=0
ADD2EOF
    ui_print "* Added new setting IPV6_PER_IFACE_ENFORCE=0 to $CONF"
  fi
  if ! grep -q '^LOG_KEEP_LINES=' "$CONF" 2>/dev/null; then
    cat >> "$CONF" << 'ADD3EOF'

# How many lines of /data/adb/dnscrypt-proxy.log to keep. Rotation kicks
# in at twice this number. Default 1500, roughly half a day.
LOG_KEEP_LINES=1500
ADD3EOF
    ui_print "* Added new setting LOG_KEEP_LINES=1500 to $CONF"
  fi
fi

ui_print "* Disabling Android 9+ Private DNS mode."
# Remember what it was, so uninstall can put it back instead of
# guessing "opportunistic" for everybody.
PREV_PDNS=$(settings get global private_dns_mode 2>/dev/null)
case "$PREV_PDNS" in
  ""|null|off) : ;;
  *) echo "$PREV_PDNS" > /data/adb/dnscrypt-prev-private-dns 2>/dev/null ;;
esac
settings put global private_dns_mode off

ui_print "* Cleaning up unnecessary files."
rm -rf "$MODPATH/binary"

ui_print " "
ui_print "* Done! DNSCrypt Proxy installed cleanly."
ui_print "* Config now lives in /data/adb/dnscrypt-proxy"
ui_print "* Edit via /storage/emulated/0/dnscrypt-proxy"
ui_print "* Reboot your device to activate."
ui_print " "
