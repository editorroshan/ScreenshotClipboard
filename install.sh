#!/bin/bash
# Builds the helper and runs it in the background at every login.
# Re-run after changing the screenshot save folder.
set -euo pipefail

LABEL="local.screenshot-clipboard"
HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/Library/Application Support/ScreenshotClipboard"
BIN="$INSTALL_DIR/screenshot-clipboard"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/screenshot-clipboard.log"

if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 13 ]; then
    echo "This needs macOS 13 Ventura or later."
    exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "Apple's command line tools are needed to build this. Run:"
    echo "    xcode-select --install"
    echo "then run this script again."
    exit 1
fi

mkdir -p "$INSTALL_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
swiftc -O -swift-version 6 "$HERE"/*.swift -o "$BIN"

# macOS's own floating thumbnail holds the file back until it goes away.
# Turn it off so captures save instantly; the helper shows its own preview.
defaults write com.apple.screencapture show-thumbnail -bool false

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
FOLDER="$(defaults read com.apple.screencapture location 2>/dev/null || echo "~/Desktop")"
echo "Installed. Captures in $FOLDER now get a floating preview, and screenshots also go to the clipboard."
echo "Log: $LOG"
