# CopyCo

CopyCo is a lightweight, native macOS menu-bar app for keeping and reusing clipboard history. It runs as an accessory app, so it stays in the menu bar without adding a Dock icon.

[简体中文](README.zh-CN.md)

[Download the latest release](https://github.com/xiaochengfu/CopyCo/releases/latest)

## Features

- **Keyboard-first workflow:** Press `⌥⌘C` to open history, type to search, use the arrow keys to select an item, and press Return to paste.
- **Native and lightweight:** Built with Swift and the macOS frameworks, with no third-party runtime dependencies.
- **Local-first privacy:** Clipboard history stays on your Mac. Nothing is uploaded.
- **Useful privacy controls:** Pause capture, exclude source applications, set retention limits, or clear history at any time.
- **Multiple clipboard types:** Keep plain text, RTF/HTML, images, file URLs, and web URLs within the configured size limits.

## Download and install

Download `CopyCo.app.zip` from [GitHub Releases](https://github.com/xiaochengfu/CopyCo/releases/latest), then:

1. Unzip the downloaded file.
2. Move `CopyCo.app` to `/Applications` or another location you use for applications.
3. Open CopyCo from Finder.

CopyCo currently requires **macOS 15 or newer**. The downloadable build is ad-hoc signed and not notarized. macOS may show a security confirmation the first time you open the app. If it blocks the launch, open the app once from Finder with Control-click → **Open**, or use **System Settings → Privacy & Security → Open Anyway** after the blocked attempt.

The current downloadable build targets Apple Silicon (`arm64`). Intel Macs are not supported by this release.

## First launch

1. Find **CopyCo** in the menu bar and open **Settings**.
2. Choose **Open Accessibility Settings**.
3. In **Privacy & Security → Accessibility**, enable CopyCo.
4. Return to CopyCo and choose **Refresh permission status**.
5. Copy something in another app, then press `⌥⌘C` to open the history panel.

Accessibility permission is only needed when CopyCo pastes directly into another app. Without it, selecting an item restores the content to the system clipboard and CopyCo asks you to paste manually with `⌘V`.

## Everyday use

| Action | How to use it |
| --- | --- |
| Open history | Press `⌥⌘C`, or use the menu-bar item. |
| Search | Start typing after the history panel opens. |
| Paste an item | Select an item and press Return. |
| Navigate | Use the Up and Down arrow keys. |
| Dismiss | Press Escape. |
| Delete | Press Forward Delete on the selected item. |
| Pause capture | Choose **Pause capture** from the menu or Settings. |
| Clear history | Choose **Clear history** when you want to remove all stored entries. |
| Exclude an app | Configure excluded source applications in Settings. |

If the destination has no text cursor, the target app is unavailable, or direct pasting cannot be completed, CopyCo prepares the selected content and guides you to click the destination. Press `⌥⌘C` again, or use `⌘V`, to finish.

The menu-bar item is also a fallback when another application already owns the global shortcut.

## Privacy and storage

CopyCo stores clipboard history locally at:

```text
~/Library/Application Support/CopyCo/History
```

The directory contains an `index.json` metadata file and local binary payload files. CopyCo has no server connection and does not upload clipboard data. The default retention limits are:

- 50 items
- 500 MiB total
- 25 MiB per captured clipboard change

Settings can increase the limits to 500 items and 1,024 MiB total. When a limit is exceeded, the oldest entries are evicted.

CopyCo ignores concealed and transient pasteboards, configured excluded applications, and known password-manager sources. When such content is skipped, CopyCo shows a short status notice so a missing history entry is not mistaken for a capture failure. Clipboard history should still be treated as sensitive local data: pause capture before copying secrets and use **Clear history** when appropriate.

### Password fields and Secure Event Input

macOS enables **Secure Event Input** while focus is in a password field. In that mode the system does not deliver Carbon global hot keys to other apps, so `⌥⌘C` (or your custom shortcut) cannot open CopyCo. This is an OS protection; CopyCo does not disable Secure Event Input.

While Secure Event Input is active, CopyCo shows a menu-bar status explaining the limit. Use the menu-bar **Show History** item instead, or leave the password field and press the shortcut again. Pasting a history item into a password field still requires Accessibility permission; CopyCo treats secure text fields as valid paste targets even when Accessibility withholds selected-text-range details.

Supported entries include plain text, RTF/HTML, images, file URLs, and web URLs. Unsupported types and entries above the per-item limit are skipped. If a stored payload is missing or corrupt on a later launch, CopyCo drops that entry instead of attempting to paste incomplete data.

## Build from source

CopyCo requires macOS 15 or newer and the Swift toolchain included with Xcode or the Command Line Tools.

Run the test suite:

```bash
swift test
```

Build the app bundle:

```bash
scripts/build-app.sh
open build/CopyCo.app
```

For the usual local loop, use the launcher. It builds the Release configuration, opens the app, and prints the first-run checklist:

```bash
scripts/run-local.sh
```

The packaging script creates `build/CopyCo.app`, removes local build paths from the binary, verifies the public bundle, and applies an anonymous ad-hoc signature for local use.

## License

CopyCo is released under the [MIT License](LICENSE).
