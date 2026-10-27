#!/bin/bash
# Wraps the built binary into a signed RemoteMyMac.app (stable identity => permissions persist).
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/sign-setup.sh
APP="$HOME/Library/Application Support/RemoteMyMac/RemoteMyMac.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/remotemymac "$APP/Contents/MacOS/remotemymac"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.remotemymac.app</string>
<key>CFBundleName</key><string>RemoteMyMac</string>
<key>CFBundleExecutable</key><string>remotemymac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>Stream your screen to your authenticated browser.</string>
</dict></plist>
P
codesign --force --sign "RemoteMyMac Local" --identifier org.remotemymac.app "$APP"
echo "$APP"
