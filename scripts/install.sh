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

# The protocol version the freshly installed daemon must answer with. The app
# passes its own HelperProtocol.version; running from the repo it is read out of
# the single source of truth. A wrong value here can only make a good install
# report failure, never the other way round.
HELPER_VERSION="${FANGLASS_HELPER_VERSION:-}"
if [ -z "$HELPER_VERSION" ] && [ -f "$SCRIPT_DIR/../Sources/Shared/HelperProtocol.swift" ]; then
    HELPER_VERSION="$(sed -n 's/.*static let version = \([0-9][0-9]*\).*/\1/p' \
        "$SCRIPT_DIR/../Sources/Shared/HelperProtocol.swift" | head -1)"
fi
if ! [ "$HELPER_VERSION" -gt 0 ] 2>/dev/null; then
    echo "error: could not determine the helper protocol version" >&2
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
# bootout is asynchronous. Bootstrapping while the old job is still unloading
# fails with "Bootstrap failed: 5: Input/output error", and a fixed sleep is a
# guess — wait for the job to actually disappear instead. This matters more than
# a first-time install failure would: an update that loses this race leaves the
# machine with the old daemon killed and no new one.
n=0
while launchctl print system/com.fanglass.helper >/dev/null 2>&1 && [ \$n -lt 25 ]; do
    sleep 0.2
    n=\$((n + 1))
done
# Retry: even after the job is gone, launchd can refuse the first bootstrap.
# kickstart is only meaningful when the job IS loaded, so it is not a fallback
# for "bootstrap never took" — it is the repair for "loaded but not running".
booted=0
for attempt in 1 2 3 4 5; do
    if launchctl bootstrap system/ /Library/LaunchDaemons/com.fanglass.helper.plist 2>/dev/null; then
        booted=1
        break
    fi
    if launchctl print system/com.fanglass.helper >/dev/null 2>&1; then
        if launchctl kickstart -k system/com.fanglass.helper 2>/dev/null; then
            booted=1
            break
        fi
    fi
    sleep 0.5
done
[ \$booted -eq 1 ] || { echo "launchctl could not start com.fanglass.helper (bootstrap failed 5 times in a row)" >&2; exit 1; }
# bootstrap returns as soon as the job is accepted, not when the daemon has
# bound its socket — and a booted-out daemon leaves its socket FILE behind, so
# a test on the path proves nothing. Prove readiness by talking to it: only a
# ping answered with this protocol version means "ready to talk to". That also
# catches an old daemon that survived the bootout and still answers an older
# version. nc is used rather than python3, which on a Mac without the Command
# Line Tools is a stub that pops an installer dialog instead of running.
n=0
ready=0
while [ \$n -lt 30 ]; do
    if printf '{"cmd":"ping"}\\n' | nc -U -w 2 /var/run/fanglass.sock 2>/dev/null \\
        | tr -d ' ' | grep -q '"version":$HELPER_VERSION'; then
        ready=1
        break
    fi
    sleep 0.2
    n=\$((n + 1))
done
[ \$ready -eq 1 ] || { echo "the helper did not answer a v$HELPER_VERSION ping on /var/run/fanglass.sock" >&2; exit 1; }
EOF
)"

# The dialog wording follows the app's UI language; FanGlass passes it in.
# Run by hand from a terminal, the script speaks English.
PROMPT="${FANGLASS_PROMPT:-FanGlass needs to install a privileged helper to control fan speed.}"

# Both the script text and the prompt are passed as arguments, not interpolated
# into AppleScript source — a path, a digest or a translation can never
# terminate the string literal.
# Don't swallow osascript errors — the app surfaces stderr if auth is canceled.
if ! osascript - "$PRIV_SCRIPT" "$PROMPT" <<'APPLESCRIPT'
on run argv
    do shell script (item 1 of argv) with administrator privileges with prompt (item 2 of argv)
end run
APPLESCRIPT
then
    echo "error: helper install was not authorized or failed" >&2
    exit 1
fi

echo "helper installed and running."
