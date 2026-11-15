#!/bin/bash
# Builds Jupiter Flasher.app into ./build (ad-hoc signed, runs on this Mac without an Apple developer account).
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Jupiter Flasher.app"
VERSION="${VERSION:-1.0.0}"

swift build -c release --product JupiterFlash
swift build -c release --product jupiterflash-cli
BIN="$(swift build -c release --show-bin-path)/JupiterFlash"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/JupiterFlash"
# Helper that performs the privileged raw write for DD mode.
cp "$(dirname "$BIN")/jupiterflash-cli" "$APP/Contents/MacOS/jupiterflash-cli"

# Icon
TMP="$(mktemp -d)"
swift scripts/make_icon.swift "$TMP/icon.png"
mkdir "$TMP/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$TMP"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Jupiter Flasher</string>
  <key>CFBundleDisplayName</key><string>Jupiter Flasher</string>
  <key>CFBundleIdentifier</key><string>io.github.jgm240.jupiter-flasher</string>
  <key>CFBundleExecutable</key><string>JupiterFlash</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Disk image</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>CFBundleTypeExtensions</key><array><string>iso</string><string>img</string></array>
  </dict></array>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRemovableVolumesUsageDescription</key><string>Jupiter Flasher writes the Windows installer files to your USB drive.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Jupiter Flasher reads the ISO you choose.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Jupiter Flasher reads the ISO you choose.</string>
</dict></plist>
PLIST

codesign --force --deep -s - "$APP"
echo "Built $APP"
