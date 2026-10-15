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
  <key>CFBundleShortVersionString</key><string>1.1.0</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSCameraUsageDescription</key><string>OpenFlo shows your camera in a bubble while you record a meeting with camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>OpenFlo listens while you hold the dictation key and transcribes on this Mac.</string>
</dict></plist>
EOF
# Sign with the maintainer's stable identity when present, so macOS keeps the Accessibility
# permission across updates; otherwise fall back to ad-hoc (permission resets on each rebuild).
ID=$(security find-certificate -c "OpenFlo Local Signing" -Z 2>/dev/null | awk '/SHA-1/{print $3}')
codesign --force --sign "${ID:--}" "$APP"
echo "Installed $APP"
