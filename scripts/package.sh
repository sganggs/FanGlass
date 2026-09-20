#!/bin/bash
# Zips build/FanGlass.app for distribution as build/FanGlass.app.zip (the name
# the READMEs point users at), then verifies that what is inside the zip still
# passes a strict signature check — the file provider on Desktop / iCloud folders
# re-stamps com.apple.FinderInfo on the bundle, and a bundle carrying that xattr
# is reported to downloaders as damaged.
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$DIR/build/FanGlass.app"
[ -d "$APP" ] || { echo "error: build first (scripts/build.sh)" >&2; exit 1; }
OUT="$DIR/build/FanGlass.app.zip"
rm -f "$OUT"
xattr -cr "$APP"
# --norsrc: no __MACOSX side files, no extended attributes in the archive.
ditto -c -k --norsrc --keepParent "$APP" "$OUT"

CHECK="$(mktemp -d "${TMPDIR:-/tmp}/fanglass-check-XXXXXX")"
trap 'rm -rf "$CHECK"' EXIT
ditto -x -k "$OUT" "$CHECK"
codesign --verify --deep --strict "$CHECK/FanGlass.app"
echo "✓ $OUT ($(du -h "$OUT" | cut -f1)), signature verified after extraction"
