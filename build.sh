#!/bin/bash
# Builds OpenFlo.app and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="$HOME/Applications/OpenFlo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp OpenFlo.icns "$APP/Contents/Resources/OpenFlo.icns"
cp .build/release/OpenFlo "$APP/Contents/MacOS/OpenFlo"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>OpenFlo</string>
  <key>CFBundleDisplayName</key><string>OpenFlo</string>
  <key>CFBundleIdentifier</key><string>com.openflo.app</string>
  <key>CFBundleIconFile</key><string>OpenFlo</string>
  <key>CFBundleExecutable</key><string>OpenFlo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>OpenFlo listens while you hold the dictation key and transcribes on this Mac.</string>
</dict></plist>
EOF
codesign --force --sign - "$APP"
echo "Installed $APP"
