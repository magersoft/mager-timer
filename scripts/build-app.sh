#!/usr/bin/env bash
# Builds build/MagerMotivate.app. With --install, copies it to ~/Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/MagerMotivate.app"

swift build -c "$CONFIG" --product MagerMotivate
BIN="$(swift build -c "$CONFIG" --show-bin-path)/MagerMotivate"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/MagerMotivate"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.magersoft.MagerMotivate</string>
  <key>CFBundleName</key><string>MagerMotivate</string>
  <key>CFBundleDisplayName</key><string>MagerMotivate</string>
  <key>CFBundleExecutable</key><string>MagerMotivate</string>
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
  pkill -x MagerMotivate || true
  rm -rf "$HOME/Applications/MagerMotivate.app"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/MagerMotivate.app"
  echo "Installed to ~/Applications/MagerMotivate.app"
fi
