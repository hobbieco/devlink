# devlink

A tab-based browser for development links on macOS. It uses the WebKit engine built into macOS (the same engine as Safari), so no browser engine is bundled.

Group links by project and environment (dev, staging, prod…). Each tab has its own cookies and storage, so you can stay signed in to several accounts of the same site at once. Data is kept in memory only and is discarded when the tab or window closes.

[한국어](README.ko.md)

## Features

- Tab-isolated website data (cookies, storage, cache): sign in to several accounts of the same site at once, no private window needed. Links opened from a page join its group tab and share the data; "Open Link in Tab" starts a separate one
- Full-page screenshots in one step (no manual scrolling), plus area screenshots, rulers and guides
- Projects → environments → links
- Split view with scroll sync
- Web Inspector and mobile view
- Per-project export and import (JSON), into a new or existing project

## Keyboard Shortcuts

| Menu | Command | Shortcut |
|---|---|---|
| File | New Tab | ⌘T |
| | Close Tab | ⌘W |
| View | Zoom In / Zoom Out / Actual Size | ⌘+ / ⌘- / ⌘0 |
| | Split View / Unsplit | ⌘D |
| | Sync Scrolling (split view only) | ⌥⌘D |
| | Developer Tools | ⌥⌘I |
| | Show / Hide Status Bar | ⌘/ |
| | Clear This Tab's Site Data | ⇧⌘⌫ |
| Capture | Capture Full Page | ⇧⌘S |
| | Capture Area | ⌥⌘S |
| | Show / Hide Rulers | ⌥⌘R |

## Build

Requires Xcode and macOS 27 or later.

1. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (ignored by git).
2. Set your own `DEVELOPMENT_TEAM` and a reverse-DNS `DEVLINK_BUNDLE_ID_PREFIX`.
3. Open `Devlink.xcodeproj` and run the `Devlink` scheme.

## Notes

Mobile view only changes the layout width and sends an iPhone Safari user agent. It does not emulate touch input or a real device, so use it as a reference and check on a real device. It also uses private WebKit APIs, so it may break on a future macOS update.

## License

[Apache License 2.0](LICENSE)
