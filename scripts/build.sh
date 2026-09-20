#!/bin/bash
# Builds FanGlass.app and the privileged helper into build/.
# No Xcode project needed — compiles directly with swiftc against the CLT SDK.
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$DIR/build"
APP="$BUILD/FanGlass.app"
SDK="$(xcrun --show-sdk-path)"
# Keep in sync with LSMinimumSystemVersion in Resources/Info.plist. The only
# macOS 26 API in the app (the top bar's Liquid Glass) is behind an #available
# check, so 15.0 is the real floor.
DEPLOY="15.0"
# Apple Silicon only by default. The whole app cross-compiles cleanly to
# x86_64, but the Intel fan path has never been exercised on real hardware —
# build a universal binary with FANGLASS_ARCHS="arm64 x86_64" if you have one.
ARCHS="${FANGLASS_ARCHS:-arm64}"
HOST_ARCH="$(uname -m)"

mkdir -p "$BUILD"

echo "▸ compiling helper…"
HELPER_SLICES=()
for ARCH in $ARCHS; do
    swiftc -O -o "$BUILD/fanglass-helper-$ARCH" \
        "$DIR/Sources/HelperTool/main.swift" \
        "$DIR/Sources/Shared/SMC.swift" "$DIR/Sources/Shared/HelperProtocol.swift" \
        -sdk "$SDK" -target "$ARCH-apple-macosx$DEPLOY" \
        -framework IOKit -framework Foundation
    HELPER_SLICES+=("$BUILD/fanglass-helper-$ARCH")
done
lipo -create -output "$BUILD/fanglass-helper" "${HELPER_SLICES[@]}"
# Sign before it is copied into Resources: --deep's handling of a plain
# executable nested in a bundle is unreliable.
codesign --force --sign - "$BUILD/fanglass-helper"

echo "▸ compiling app…"
APP_SOURCES=()
while IFS= read -r -d "" f; do APP_SOURCES+=("$f"); done \
    < <(find "$DIR/Sources/FanGlass" "$DIR/Sources/Shared" -name "*.swift" -print0)
APP_SLICES=()
for ARCH in $ARCHS; do
    swiftc -O -o "$BUILD/FanGlass-$ARCH" "${APP_SOURCES[@]}" \
        -sdk "$SDK" -target "$ARCH-apple-macosx$DEPLOY" \
        -module-name FanGlass \
        -framework SwiftUI -framework Foundation -framework IOKit \
        -framework UserNotifications -framework ServiceManagement -framework AppKit
    APP_SLICES+=("$BUILD/FanGlass-$ARCH")
done
lipo -create -output "$BUILD/FanGlass" "${APP_SLICES[@]}"

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
        -sdk "$SDK" -target "$HOST_ARCH-apple-macosx$DEPLOY" -framework AppKit 2>/dev/null \
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
