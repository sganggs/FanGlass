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
# A helper unzipped from a download carries com.apple.quarantine; without this
# it would be copied, quarantine and all, into /Library/PrivilegedHelperTools.
xattr -d com.apple.quarantine "$STAGE/fanglass-helper" 2>/dev/null || true

PRIV="$STAGE/install-priv.sh"
cat > "$PRIV" <<EOF
#!/bin/bash
set -e
mkdir -p /Library/PrivilegedHelperTools
cp "$STAGE/fanglass-helper" /Library/PrivilegedHelperTools/fanglass-helper
chmod 755 /Library/PrivilegedHelperTools/fanglass-helper
chown root:wheel /Library/PrivilegedHelperTools/fanglass-helper
cp "$STAGE/com.fanglass.helper.plist" /Library/LaunchDaemons/com.fanglass.helper.plist
chmod 644 /Library/LaunchDaemons/com.fanglass.helper.plist
chown root:wheel /Library/LaunchDaemons/com.fanglass.helper.plist
launchctl bootout system/com.fanglass.helper 2>/dev/null || true
sleep 1
launchctl bootstrap system/ /Library/LaunchDaemons/com.fanglass.helper.plist 2>/dev/null \
    || launchctl kickstart -k system/com.fanglass.helper
# bootstrap returns as soon as the job is accepted, not when the daemon has
# bound its socket. Wait for it so a zero exit really means "ready to talk to".
n=0
while [ ! -S /var/run/fanglass.sock ] && [ \$n -lt 25 ]; do
    sleep 0.2
    n=\$((n + 1))
done
EOF
chmod +x "$PRIV"

# Don't swallow osascript errors — the app surfaces stderr if auth is canceled.
if ! osascript -e "do shell script \"$PRIV\" with administrator privileges with prompt \"FanGlass 需要安装特权助手来控制风扇转速。\""; then
    echo "error: helper install was not authorized or failed" >&2
    exit 1
fi

echo "helper installed and running."
