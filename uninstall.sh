#!/bin/bash
# Stops the helper and removes everything install.sh put in ~/Library.
set -euo pipefail

LABEL="local.screenshot-clipboard"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Library/Application Support/ScreenshotClipboard"

# Bring back macOS's own floating thumbnail, which install.sh turned off.
defaults delete com.apple.screencapture show-thumbnail 2>/dev/null || true
echo "Uninstalled."
