#!/bin/bash
# Removes the fanglass privileged helper daemon.
osascript -e 'do shell script "launchctl bootout system/com.fanglass.helper 2>/dev/null; rm -f /Library/LaunchDaemons/com.fanglass.helper.plist /Library/PrivilegedHelperTools/fanglass-helper /var/run/fanglass.sock" with administrator privileges with prompt "FanGlass 需要授权以卸载特权助手。"' >/dev/null
echo "helper uninstalled."
