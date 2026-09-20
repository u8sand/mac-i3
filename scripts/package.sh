#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 mac-i3 contributors

# Builds dist/mac-i3.app (universal), then dist/mac-i3-<version>.dmg and .zip.
#
#   scripts/package.sh                                 # ad-hoc signed: fine on this Mac; other Macs need right-click > Open once
#   SIGN_IDENTITY="Developer ID Application: You (TEAMID)" scripts/package.sh
#   SIGN_IDENTITY=... NOTARY_PROFILE=mac-i3 scripts/package.sh    # + notarize and staple (needs an Apple Developer account;
#                                                                 #   create the profile once with `xcrun notarytool store-credentials`)
#
# Other knobs: BUNDLE_ID, SOURCE_URL, VERSION (default: the VERSION file), BUILD (default: git commit count), ARCHS ("arm64 x86_64").
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID=${BUNDLE_ID:-io.github.u8sand.mac-i3}
SOURCE_URL=${SOURCE_URL:-https://github.com/u8sand/mac-i3}
VERSION=${VERSION:-$(tr -d '[:space:]' < VERSION)}
BUILD=${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
ARCHS=${ARCHS:-"arm64 x86_64"}
DIST=dist
APP=$DIST/mac-i3.app

say() { printf '\n==> %s\n' "$*"; }

say "building release ($ARCHS)"
# One build per architecture, merged with lipo: SwiftPM's own --arch a --arch b needs Xcode's xcbuild, which the
# Command Line Tools do not include.
SLICES=()
for a in $ARCHS; do
    # A scratch directory per architecture: sharing one build directory between triples confuses SwiftPM's cache.
    FLAGS=(-c release --triple "$a-apple-macosx13.0" --scratch-path ".build-pkg/$a")
    swift build "${FLAGS[@]}"
    SLICES+=("$(swift build "${FLAGS[@]}" --show-bin-path)/mac-i3")
done
BIN="$DIST/mac-i3-universal"
mkdir -p "$DIST"
if [ "${#SLICES[@]}" -gt 1 ]; then lipo -create "${SLICES[@]}" -output "$BIN"; else cp "${SLICES[0]}" "$BIN"; fi
[ -x "$BIN" ] || { echo "missing $BIN" >&2; exit 1; }

say "assembling $APP ($VERSION, build $BUILD, $BUNDLE_ID)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp LICENSE "$APP/Contents/Resources/LICENSE"      # GPL-3.0: the license travels with every copy of the binary
cp "$BIN" "$APP/Contents/MacOS/mac-i3"
rm -f "$BIN"
BIN="$APP/Contents/MacOS/mac-i3"
sed -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" -e "s|@VERSION@|$VERSION|g" -e "s|@BUILD@|$BUILD|g" \
    packaging/Info.plist.in > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"

say "rendering the icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$BIN" render-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

say "signing (${SIGN_IDENTITY/#-/ad-hoc})"
SIGN_ARGS=(--force --options runtime --sign "$SIGN_IDENTITY")
[ "$SIGN_IDENTITY" != "-" ] && SIGN_ARGS+=(--timestamp)
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    [ "$SIGN_IDENTITY" != "-" ] || { echo "NOTARY_PROFILE needs a real SIGN_IDENTITY (Developer ID Application)" >&2; exit 1; }
    say "notarizing (this waits for Apple, usually a few minutes)"
    NOTARIZE_ZIP="$(mktemp -d)/mac-i3.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARIZE_ZIP"
    xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
fi

say "packaging"
ZIP="$DIST/mac-i3-$VERSION.zip"
DMG="$DIST/mac-i3-$VERSION.dmg"
rm -f "$ZIP" "$DMG"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

STAGE="$(mktemp -d)/mac-i3"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp LICENSE "$STAGE/LICENSE"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<TXT
mac-i3 $VERSION

1. Drag mac-i3 onto Applications.
2. Open it from Applications. If macOS says it cannot verify the app (this build is not notarized),
   right-click mac-i3 > Open > Open, once. Or in Terminal:
       xattr -dr com.apple.quarantine /Applications/mac-i3.app
3. Allow mac-i3 in System Settings > Privacy & Security > Accessibility and Input Monitoring.
   It starts by itself as soon as you do.

It lives in the menu bar (no Dock icon). Right-click its item for Reload / Edit Config / Launch at Login / Quit.
Your configuration is ~/.config/mac-i3/config.

mac-i3 is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License
as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
See LICENSE. Copies you distribute must stay under the same license, with their source code available.

Source code, releases and bug reports: $SOURCE_URL
TXT
hdiutil create -volname "mac-i3 $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
[ "$SIGN_IDENTITY" != "-" ] && codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

( cd "$DIST" && shasum -a 256 "mac-i3-$VERSION.dmg" "mac-i3-$VERSION.zip" > SHA256SUMS )

say "done"
ls -lh "$DIST" | sed 's/^/    /'
lipo -info "$APP/Contents/MacOS/mac-i3" | sed 's/^/    /'
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|flags" | sed 's/^/    /'
