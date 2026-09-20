#!/bin/bash
# Builds FanGlass.app and the privileged helper into build/.
# No Xcode project needed — compiles directly with swiftc against the CLT SDK.
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$DIR/build"
APP="$BUILD/FanGlass.app"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macosx26.0"

mkdir -p "$BUILD"

echo "▸ compiling helper…"
swiftc -O -o "$BUILD/fanglass-helper" \
    "$DIR/Sources/HelperTool/main.swift" \
    "$DIR/Sources/Shared/SMC.swift" "$DIR/Sources/Shared/HelperProtocol.swift" \
    -sdk "$SDK" -target "$TARGET" \
    -framework IOKit -framework Foundation
# Sign before it is copied into Resources: --deep's handling of a plain
# executable nested in a bundle is unreliable.
codesign --force --sign - "$BUILD/fanglass-helper"

echo "▸ compiling app…"
find "$DIR/Sources/FanGlass" "$DIR/Sources/Shared" -name "*.swift" -print0 \
| xargs -0 swiftc -O -o "$BUILD/FanGlass" \
    -sdk "$SDK" -target "$TARGET" \
    -module-name FanGlass \
    -framework SwiftUI -framework Foundation -framework IOKit \
    -framework UserNotifications -framework ServiceManagement -framework AppKit

echo "▸ assembling FanGlass.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/scripts"
cp "$BUILD/FanGlass" "$APP/Contents/MacOS/FanGlass"
cp "$DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
# Bundle the helper + installer so the app can (re)install it from Settings.
cp "$BUILD/fanglass-helper" "$APP/Contents/Resources/fanglass-helper"
cp "$DIR/Resources/com.fanglass.helper.plist" "$APP/Contents/Resources/com.fanglass.helper.plist"
cp "$DIR/scripts/install.sh" "$APP/Contents/Resources/scripts/install.sh"
cp "$DIR/scripts/uninstall.sh" "$APP/Contents/Resources/scripts/uninstall.sh"
chmod +x "$APP/Contents/Resources/scripts/"*.sh

# App icon (generated; safe to skip if generation fails).
if [ -f "$DIR/tools/make_icon.swift" ]; then
    echo "▸ generating icon…"
    swiftc -O -o "$BUILD/make_icon" "$DIR/tools/make_icon.swift" \
        -sdk "$SDK" -target "$TARGET" -framework AppKit 2>/dev/null \
    && "$BUILD/make_icon" "$BUILD/icon_1024.png" 2>/dev/null \
    && {
        ICONSET="$BUILD/AppIcon.iconset"
        rm -rf "$ICONSET"; mkdir -p "$ICONSET"
        for spec in "16:16:1" "32:16:2" "32:32:1" "64:32:2" "128:128:1" "256:128:2" "256:256:1" "512:256:2" "512:512:1" "1024:512:2"; do
            px="${spec%%:*}"; rest="${spec#*:}"; base="${rest%%:*}"; scale="${rest##*:}"
            sips -z "$px" "$px" "$BUILD/icon_1024.png" --out "$ICONSET/icon_${base}x${base}$( [ "$scale" = "2" ] && echo "@2x" ).png" >/dev/null
        done
        iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
    } || true
fi

echo "▸ signing (ad-hoc)…"
# A source tree on the Desktop or in an iCloud folder leaves com.apple.FinderInfo
# on the bundle, and codesign refuses it ("resource fork, Finder information, or
# similar detritus not allowed"). This used to be silenced with `|| true`, which
# shipped a bundle carrying only swiftc's linker signature — no sealed resources,
# which Gatekeeper reports to the downloader as 已损坏 with no way to open it.
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
# The file provider re-stamps FinderInfo within seconds of the bundle changing,
# and --strict refuses it; clear again so the check tests the signature, not sync.
xattr -cr "$APP"
codesign --verify --deep --strict "$APP"

echo "✓ $APP"
