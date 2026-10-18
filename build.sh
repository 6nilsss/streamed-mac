#!/bin/bash
# Builds Streamed.app with the Command Line Tools (no Xcode needed) and installs it to ~/Applications.
set -e
cd "$(dirname "$0")"
APP=build/Streamed.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -framework AppKit -framework WebKit main.swift -o "$APP/Contents/MacOS/Streamed" 2>&1 | grep -vE '^\s*$' || true
[ -x "$APP/Contents/MacOS/Streamed" ] || { echo BUILD_FAILED; exit 1; }

if [ ! -f build/AppIcon.icns ]; then
  swiftc -swift-version 5 icon.swift -o build/icongen && build/icongen build/icon1024.png
  IS=build/AppIcon.iconset; rm -rf $IS; mkdir -p $IS
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz build/icon1024.png --out $IS/icon_${sz}x${sz}.png >/dev/null
    sips -z $((sz*2)) $((sz*2)) build/icon1024.png --out $IS/icon_${sz}x${sz}@2x.png >/dev/null
  done
  iconutil -c icns $IS -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>at.nils.streamed</string>
  <key>CFBundleName</key><string>Streamed</string>
  <key>CFBundleDisplayName</key><string>Streamed</string>
  <key>CFBundleExecutable</key><string>Streamed</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>__VERSION__</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.sports</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
EOF

sed -i '' "s/__VERSION__/$(cat VERSION 2>/dev/null || echo 1.0)/" "$APP/Contents/Info.plist"
codesign --force --deep -s - "$APP" >/dev/null 2>&1
mkdir -p ~/Applications
rm -rf ~/Applications/Streamed.app
cp -R "$APP" ~/Applications/
echo BUILD_OK
