<h1 align="center">ScreenshotClipboard</h1>

<p align="center"><b>Screenshots on macOS that save the moment you capture, pop up a preview, and land on your clipboard.</b></p>

<p align="center">macOS 13+ · Apple Silicon &amp; Intel · Free &amp; open source</p>

With macOS's floating thumbnail on, a screenshot isn't saved until the thumbnail slides
away, about 5 seconds later. It only goes to the clipboard if you remember to hold Control.
ScreenshotClipboard turns the system thumbnail off so every capture saves **instantly**.
Then it shows its own floating preview and copies each new screenshot to the clipboard.

## Features

- **Instant saving** for screenshots and screen recordings (⌘⇧3, ⌘⇧4, ⌘⇧5), into the
  folder you picked in the Screenshot app.
- **On the clipboard:** every new screenshot is copied, ready for ⌘V. The file is still
  saved as usual.
- **Floating preview** in the bottom-right corner of the screen you're working on:
  - **Click** to open it in Preview (to mark up) or QuickTime Player (to trim).
  - **Drag** it into any app or folder to drop a copy of the file there.
  - **Two-finger swipe right** to dismiss it. Otherwise it hides after 5 seconds, and
    hovering keeps it open.
  - **Right-click** for Open, Show in Finder, Move to Trash and Close.
  - Recordings show a play badge with their length.
- Runs in the background with no Dock or menu-bar icon, and sleeps until a new file shows up.
- No network access, no tracking. Everything stays on your Mac.

## Requirements

- macOS 13 Ventura or newer (developed on macOS 26 Tahoe)
- Apple's free Command Line Tools, for the Swift compiler. The installer tells you if
  they're missing (install them with `xcode-select --install`).

## Install

1. **Pick where captures save:** press ⌘⇧5, click **Options**, and choose a folder under
   **Save to** (**Other Location…** for your own).
2. **Get the code and install it.** With git:

   ```bash
   git clone https://github.com/editorroshan/ScreenshotClipboard.git
   cd ScreenshotClipboard
   bash install.sh
   ```

   Without git: click **Code → Download ZIP** on GitHub and unzip it. Open **Terminal**,
   type `cd ` (with a space), drag the unzipped folder into the Terminal window, press
   Return, then run `bash install.sh`.
3. **Allow folder access:** macOS asks whether **screenshot-clipboard** may access your
   Desktop or Documents folder (wherever your captures go). Click **Allow**. Without it,
   the helper can't see new captures.

That's it. Try ⌘⇧4. The helper starts by itself at every login, and installing needs no
admin password.

If you change the save folder later, run `bash install.sh` again.

## Update

```bash
cd ScreenshotClipboard
git pull
bash install.sh
```

macOS asks for folder access again after each update. The helper isn't signed with a
certificate, so every new build looks like a new program to macOS.

## Uninstall

```bash
bash uninstall.sh
```

This removes the helper and its login item and turns macOS's own floating thumbnail back on.

## Troubleshooting

- **No preview or clipboard copy.** Open System Settings → Privacy & Security →
  Files & Folders and make sure **screenshot-clipboard** is allowed.
- **Something else.** The log is at `~/Library/Logs/screenshot-clipboard.log`. It shows
  each file the helper saw, copied or previewed.

## How it works

ScreenshotClipboard is a small Swift/AppKit program with no dependencies. `install.sh`
builds it on your Mac. The script then turns off the system thumbnail
(`com.apple.screencapture show-thumbnail`) and registers a LaunchAgent, so macOS's `launchd`
starts the helper at login and restarts it if it ever stops.

The helper reads your screenshot folder from the Screenshot app's own setting and asks macOS
to tell it when that folder changes. It doesn't hook into the screenshot tool at all. When a
new image appears, it puts the PNG on the clipboard (a TIFF copy is made only if an app asks
for one) and shows a preview made with Quick Look. A new recording gets a preview as soon as
the file is readable.

```
main.swift      watching the folder, the clipboard
Preview.swift   the floating preview
install.sh      build, turn off the system thumbnail, add the login item
uninstall.sh    remove everything and bring the system thumbnail back
```

Installed files:

- `~/Library/Application Support/ScreenshotClipboard/screenshot-clipboard`: the helper
- `~/Library/LaunchAgents/local.screenshot-clipboard.plist`: the login item
- `~/Library/Logs/screenshot-clipboard.log`: the log

## License

[MIT](LICENSE). Use it, change it, share it.
