#!/bin/bash
# Removes the fanglass privileged helper daemon.
# Shows one administrator authorization dialog (osascript).
set -euo pipefail

# The dialog wording follows the app's UI language; FanGlass passes it in.
# Run by hand from a terminal, the script speaks English.
PROMPT="${FANGLASS_PROMPT:-FanGlass needs authorization to uninstall the privileged helper.}"

# bootout first: it sends SIGTERM, and the helper restores automatic fan
# control before exiting. Then remove everything the install put on the disk —
# the log and its rotation rule included, or an uninstall leaves root-owned
# files behind on the boot volume.
REMOVE='launchctl bootout system/com.fanglass.helper 2>/dev/null; rm -f /Library/LaunchDaemons/com.fanglass.helper.plist /Library/PrivilegedHelperTools/fanglass-helper /var/run/fanglass.sock /etc/newsyslog.d/com.fanglass.helper.conf /var/log/fanglass-helper.log /var/log/fanglass-helper.log.*'

# Command and prompt are passed as arguments, never interpolated into the
# AppleScript source, so a translated prompt cannot end the string literal.
# Don't swallow osascript's stderr — the app reads it to tell a declined
# authorization (-128) from a real failure. Without the exit check this script
# reported success even when the user dismissed the password dialog.
if ! osascript - "$REMOVE" "$PROMPT" <<'APPLESCRIPT' >/dev/null
on run argv
    do shell script (item 1 of argv) with administrator privileges with prompt (item 2 of argv)
end run
APPLESCRIPT
then
    echo "error: helper uninstall was not authorized or failed" >&2
    exit 1
fi
echo "helper uninstalled."
