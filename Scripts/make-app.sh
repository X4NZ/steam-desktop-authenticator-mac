#!/bin/bash
# Builds SDA.app, a self-contained macOS application bundle.
#
# SwiftPM produces a bare executable; macOS needs a bundle for the menu bar
# extra, notifications and keychain access to behave. This assembles one.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP_NAME="Steam Desktop Authenticator"
BUNDLE_ID="com.sdamac.SDA"
# The release workflow passes the tag in as VERSION; a local build is a dev build.
VERSION="${VERSION:-1.0.0}"
# Where "Check for Updates" looks. Must match the repo releases are published to.
UPDATE_REPO="${UPDATE_REPO:-X4NZ/steam-desktop-authenticator-mac}"
APP="build/${APP_NAME}.app"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --product SDA

BINARY="$(swift build -c "$CONFIG" --product SDA --show-bin-path)/SDA"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/SDA"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleExecutable</key><string>SDA</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>SDAUpdateRepository</key><string>${UPDATE_REPO}</string>
</dict>
</plist>
PLIST

echo "==> Rendering icon"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swift Scripts/make-icon.swift build/icon-1024.png >/dev/null

for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" \
            "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
    set -- $spec
    sips -z "$1" "$1" build/icon-1024.png --out "$ICONSET/icon_$2.png" >/dev/null 2>&1
done

iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad-hoc)"
# An ad-hoc signature is enough for the keychain and notifications to work
# locally. Distributing it would need a Developer ID instead.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
    || echo "    (signing failed; the app still runs)"

echo
echo "Built $APP  (version ${VERSION}, updates from ${UPDATE_REPO})"
echo "Run it with:  open \"$APP\""
