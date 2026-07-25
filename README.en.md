# QuitHide

[中文](README.md)

QuitHide is a native macOS menu bar utility that automatically hides or gracefully quits apps after they have stayed in the background for a configurable amount of time.

![QuitHide menu bar interface](assets/quithide-screenshot.png)

## Features

- Automatically hide apps without an explicit rule after the default delay
- Choose Ignore, Hide, or Quit independently for each app
- Set a separate delay for every automated rule
- See the remaining time and next action for each app
- Start a fresh countdown after an app becomes active again
- Hide or quit all matching apps immediately
- Pause automation at any time
- Optionally launch at login
- Check for updates automatically once per day by default, or manually in Settings
- Keep Ignore, automatic Hide, and automatic Quit rules visible while apps are not running
- Show ignored apps in the same horizontal rows as other rules; offline apps appear dimmed

## Requirements

- macOS 13 Ventura or later
- Apple Silicon or Intel Mac (Universal 2)

## Download and installation

1. Download the latest `.dmg` from [GitHub Releases](https://github.com/jiangsir-tech/QuitHide/releases).
2. Open the DMG and drag `QuitHide.app` into Applications.
3. Launch QuitHide and use its menu bar icon to configure app rules.

Official release packages are signed with an Apple Developer ID and notarized by Apple. Only install builds downloaded from this repository's Releases page.

### What's new in 0.3.0

- Versioned migration, corruption recovery, and offline retention for independent app rules
- New Running and All Rules views, default hiding, and optional pre-quit hiding
- Explicit normal-quit timeout status with a separately confirmed manual force-quit action
- Update checks now exclude prereleases and validate system compatibility and download URLs
- Improved menu sizing and natural ordering across English names and Chinese Pinyin

## How it works

On a fresh install, both switches under **Additional Rules** are off. Enable either one only when needed; each starts with a five-minute delay that you can change.

The main menu opens in **Running**, showing every current app in this order: Ignore, Unconfigured, Automatic Hide, and Automatic Quit. **All Rules** keeps the Ignore, Automatic Hide, and Automatic Quit sections; each header shows both the total and running counts. Running apps come first within each section, followed by one natural order across English names and Chinese Pinyin. Offline apps appear dimmed.

The menu window adapts to the number of currently running apps and visible groups. Once it reaches its height limit, the list scrolls instead. **All Rules** and search results keep that same height so switching or typing does not make the window jump.

Search combines matching apps into one result list instead of splitting them by rule type. Clearing the query restores the normal sections.

Choose Ignore, Hide, or Quit beside an app to override the default. Ignore means QuitHide never handles that app; explicit Hide and Quit rules store their own delays. Explicit rules remain visible and editable while their apps are not running, with dimmed app identity.

The immediate Hide and Quit buttons run matching rules early without changing them. Manual actions remain available while automation is paused.

Quit sends the standard macOS termination request rather than force-killing a process. Each target app remains responsible for warning about unsaved work.

If an app is still running 30 seconds after a normal quit request, its status changes to **Quit Not Completed**. You can right-click it to request a normal quit again or choose **Force Quit…**, which always requires confirmation. Force Quit is manual only and is never used by automatic rules; unsaved work may be lost.

**Automatically Check for Updates** is on by default. QuitHide waits briefly after launch and checks at most once every 24 hours. When it finds a new stable version compatible with the current macOS, it shows a reminder the next time you open the menu, where you can open the download page, be reminded again in 24 hours, or skip that version. You can disable automatic checks in Settings, and manual checks always remain available. QuitHide only opens this project's GitHub Releases page; it never downloads, installs, or restarts the app by itself.

## Privacy

QuitHide runs locally. It contains no analytics services or third-party dependencies, and it never uploads running-app information or saved rules. When automatic update checks are enabled, QuitHide performs at most one check every 24 hours: it first accesses this project's GitHub update manifest and may query GitHub Releases plus the candidate stable tag's compatibility manifest if the main manifest is unavailable. A release is not offered when compatibility cannot be confirmed. Manual checks use the same flow. These requests are used only to compare versions and contain no app list or saved rules.

## Build from source

The Apple Swift toolchain is required. Run the core regression tests first:

```sh
./scripts/test.sh
```

Then build the Universal 2 app with:

```sh
./scripts/build-app.sh
```

Maintainers can use the notarization credentials stored in Keychain to create a signed and notarized release:

```sh
./scripts/release-notarized.sh
```

Create the DMG and its SHA-256 checksum for GitHub Releases with:

```sh
./scripts/build-dmg.sh
```

Artifacts are written to `dist/`.

## License

[MIT License](LICENSE)
