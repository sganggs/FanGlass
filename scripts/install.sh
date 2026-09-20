#!/bin/bash
# Installs the fanglass privileged helper as a launchd daemon.
# Works from the repo (scripts/install.sh) and from inside FanGlass.app.
# Shows one administrator authorization dialog (osascript).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Prefer paths the app passes in; then bundled Resources/; then the repo layout.
if [ -n "${FANGLASS_HELPER:-}" ] && [ -x "$FANGLASS_HELPER" ]; then
    HELPER="$FANGLASS_HELPER"
    PLIST="${FANGLASS_PLIST:-}"
elif [ -x "$SCRIPT_DIR/../fanglass-helper" ]; then
    # FanGlass.app/Contents/Resources/scripts/install.sh
    HELPER="$SCRIPT_DIR/../fanglass-helper"
    PLIST="$SCRIPT_DIR/../com.fanglass.helper.plist"
elif [ -x "$SCRIPT_DIR/../build/fanglass-helper" ]; then
    # repo scripts/install.sh
    HELPER="$SCRIPT_DIR/../build/fanglass-helper"
    PLIST="$SCRIPT_DIR/../Resources/com.fanglass.helper.plist"
else
    echo "error: fanglass-helper not found (looked next to the script and in build/)" >&2
    exit 1
fi

if [ ! -f "$PLIST" ]; then
    echo "error: helper plist not found at $PLIST" >&2
    exit 1
fi

# Stage into /tmp first: the privileged shell spawned by osascript has no
# TCC permission to read from ~/Desktop (or other user folders).
STAGE="$(mktemp -d /tmp/fanglass-stage-XXXXXX)"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

cp "$HELPER" "$STAGE/fanglass-helper"
cp "$PLIST" "$STAGE/com.fanglass.helper.plist"
chmod 755 "$STAGE/fanglass-helper"
# Files unzipped from a download carry com.apple.quarantine; without this they
# would be copied, quarantine and all, into /Library — and Gatekeeper refuses
# to start a quarantined launchd daemon.
xattr -d com.apple.quarantine "$STAGE/fanglass-helper" 2>/dev/null || true
xattr -d com.apple.quarantine "$STAGE/com.fanglass.helper.plist" 2>/dev/null || true

# Digests taken BEFORE authorization, re-checked as root after it. $STAGE is
# mode 0700, which keeps other users out but is no protection at all against
# another process running as this user — and the gap between staging and the
# root copy is as long as the user takes to type a password. Without this,
# anything running as the user could swap the binary in that window and have
# it installed as a root daemon.
HELPER_SHA="$(shasum -a 256 "$STAGE/fanglass-helper" | awk '{print $1}')"
PLIST_SHA="$(shasum -a 256 "$STAGE/com.fanglass.helper.plist" | awk '{print $1}')"

# Built here, run as root by osascript. Never written to disk: a script file
# would be user-writable right up to the moment root executes it.
PRIV_SCRIPT="$(cat <<EOF
set -e
[ "\$(shasum -a 256 '$STAGE/fanglass-helper' | cut -d' ' -f1)" = '$HELPER_SHA' ] \\
    || { echo 'staged helper changed after authorization' >&2; exit 1; }
[ "\$(shasum -a 256 '$STAGE/com.fanglass.helper.plist' | cut -d' ' -f1)" = '$PLIST_SHA' ] \\
    || { echo 'staged plist changed after authorization' >&2; exit 1; }
mkdir -p /Library/PrivilegedHelperTools
cp '$STAGE/fanglass-helper' /Library/PrivilegedHelperTools/fanglass-helper
chmod 755 /Library/PrivilegedHelperTools/fanglass-helper
chown root:wheel /Library/PrivilegedHelperTools/fanglass-helper
cp '$STAGE/com.fanglass.helper.plist' /Library/LaunchDaemons/com.fanglass.helper.plist
chmod 644 /Library/LaunchDaemons/com.fanglass.helper.plist
chown root:wheel /Library/LaunchDaemons/com.fanglass.helper.plist
# Gatekeeper refuses to launch a quarantined daemon, and cp carries xattrs over
# from a bundle the user downloaded rather than built.
xattr -dr com.apple.quarantine /Library/PrivilegedHelperTools/fanglass-helper \\
    /Library/LaunchDaemons/com.fanglass.helper.plist 2>/dev/null || true
# The helper logs to a root-owned file on the boot volume; rotate it.
mkdir -p /etc/newsyslog.d
printf '%s\\n' '/var/log/fanglass-helper.log 644 3 1024 * J' \\
    > /etc/newsyslog.d/com.fanglass.helper.conf
chmod 644 /etc/newsyslog.d/com.fanglass.helper.conf
launchctl bootout system/com.fanglass.helper 2>/dev/null || true
sleep 1
launchctl bootstrap system/ /Library/LaunchDaemons/com.fanglass.helper.plist 2>/dev/null \\
    || launchctl kickstart -k system/com.fanglass.helper
# bootstrap returns as soon as the job is accepted, not when the daemon has
# bound its socket. Wait for it so a zero exit really means "ready to talk to".
n=0
while [ ! -S /var/run/fanglass.sock ] && [ \$n -lt 25 ]; do
    sleep 0.2
    n=\$((n + 1))
done
[ -S /var/run/fanglass.sock ] || { echo "helper did not bind its socket" >&2; exit 1; }
EOF
)"

# The script text is passed as an argument, not interpolated into AppleScript
# source — a path or digest can never terminate the string literal.
# Don't swallow osascript errors — the app surfaces stderr if auth is canceled.
if ! osascript - "$PRIV_SCRIPT" <<'APPLESCRIPT'
on run argv
    do shell script (item 1 of argv) with administrator privileges with prompt "FanGlass 需要安装特权助手来控制风扇转速。"
end run
APPLESCRIPT
then
    echo "error: helper install was not authorized or failed" >&2
    exit 1
fi

echo "helper installed and running."
