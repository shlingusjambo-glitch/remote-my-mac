#!/bin/bash
# Builds RemoteMyMac, installs it for your user, and registers a LaunchAgent that restarts it if it ever dies.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
DEST="$HOME/Library/Application Support/RemoteMyMac"
mkdir -p "$DEST/bin" && chmod 700 "$DEST"
APP=$(./scripts/bundle.sh | tail -1)
BIN="$APP/Contents/MacOS/remotemymac"
PLIST="$HOME/Library/LaunchAgents/org.remotemymac.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>org.remotemymac</string>
  <key>ProgramArguments</key><array><string>$BIN</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardErrorPath</key><string>$DEST/remotemymac.log</string>
</dict></plist>
PL
echo "Installed app: $APP"
echo "Next:"
echo "  1. \"$BIN\" setup"
echo "  2. \"$BIN\" permissions   (then approve it in System Settings > Privacy & Security)"
echo "  3. launchctl bootstrap gui/\$(id -u) \"$PLIST\""
echo "  4. Set up the Cloudflare Tunnel (see README)"
