#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Riffnote"
APP_BUNDLE="$ROOT/.build/installer/$APP_NAME.app"
PKG_ROOT="$ROOT/.build/installer/pkgroot"
ICON_FILE="$ROOT/Assets/AppIcon.icns"
OUTPUT="$ROOT/dist/$APP_NAME-Installer.pkg"
ARM_PRODUCT="$ROOT/.build/DerivedData/Build/Products/Release/$APP_NAME"
INTEL_PRODUCT="$ROOT/.build/IntelDerivedData/Build/Products/Release/$APP_NAME"

cd "$ROOT"
if [[ ! -x "$ARM_PRODUCT" || Package.swift -nt "$ARM_PRODUCT" || sources/riffnote/RiffnoteApp.swift -nt "$ARM_PRODUCT" ]]; then
  xcodebuild -scheme "$APP_NAME" -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath .build/DerivedData \
    DEBUG_INFORMATION_FORMAT=dwarf build
fi
if [[ ! -x "$INTEL_PRODUCT" || Package.swift -nt "$INTEL_PRODUCT" || sources/riffnote/RiffnoteApp.swift -nt "$INTEL_PRODUCT" ]]; then
  xcodebuild -scheme "$APP_NAME" -configuration Release \
    -destination 'platform=macOS,arch=x86_64' \
    -derivedDataPath .build/IntelDerivedData \
    DEBUG_INFORMATION_FORMAT=dwarf build
fi

rm -rf "$APP_BUNDLE" "$PKG_ROOT"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$PKG_ROOT" "$ROOT/dist"
lipo -create "$ARM_PRODUCT" "$INTEL_PRODUCT" -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ICON_FILE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Riffnote</string>
	<key>CFBundleIdentifier</key>
	<string>com.riffnote.app</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleName</key>
	<string>Riffnote</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_BUNDLE"
cp -R "$APP_BUNDLE" "$PKG_ROOT/"

rm -f "$OUTPUT"
pkgbuild --root "$PKG_ROOT" --identifier com.riffnote.installer \
  --version 1.0 --install-location /Applications "$OUTPUT"
echo "Installer creato: $OUTPUT"
