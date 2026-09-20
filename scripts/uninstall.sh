#!/bin/bash
# Removes the fanglass privileged helper daemon.
# Shows one administrator authorization dialog (osascript).
set -euo pipefail

# Don't swallow osascript's stderr — the app reads it to tell a declined
# authorization (-128) from a real failure. Without the exit check this script
# reported success even when the user dismissed the password dialog.
if ! osascript -e 'do shell script "launchctl bootout system/com.fanglass.helper 2>/dev/null; rm -f /Library/LaunchDaemons/com.fanglass.helper.plist /Library/PrivilegedHelperTools/fanglass-helper /var/run/fanglass.sock" with administrator privileges with prompt "FanGlass 需要授权以卸载特权助手。"' >/dev/null; then
    echo "error: helper uninstall was not authorized or failed" >&2
    exit 1
fi
echo "helper uninstalled."
