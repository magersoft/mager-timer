#!/usr/bin/env bash
# Builds build/MagerTimer.app. With --install, moves it to ~/Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/MagerTimer.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

swift build -c "$CONFIG" --product MagerTimer
BIN="$(swift build -c "$CONFIG" --show-bin-path)/MagerTimer"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MagerTimer"

# Resources/AppIcon.png is drawn by scripts/make-icon.swift; Finder, Spotlight and notifications want an .icns.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.magersoft.MagerTimer</string>
  <key>CFBundleName</key><string>MagerTimer</string>
  <key>CFBundleDisplayName</key><string>MagerTimer</string>
  <key>CFBundleExecutable</key><string>MagerTimer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x MagerTimer || true
  # The app used to be called MagerMotivate; drop the old copy so it doesn't linger in Launchpad and login items.
  pkill -x MagerMotivate || true
  rm -rf "$HOME/Applications/MagerMotivate.app" build/MagerMotivate.app
  rm -rf "$HOME/Applications/MagerTimer.app"
  cp -R "$APP" "$HOME/Applications/"
  # Otherwise Launchpad and Spotlight list the build copy as a second MagerTimer.
  "$LSREGISTER" -u "$APP" 2>/dev/null || true
  rm -rf "$APP"
  open "$HOME/Applications/MagerTimer.app"
  echo "Installed to ~/Applications/MagerTimer.app"
fi
