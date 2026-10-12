# ContextRoute

A small macOS utility for routing links from **source apps to browsers and profiles**.

## How it works

- ContextRoute first checks enabled handlers in **Open in apps**. Matching links open directly in the installed app. If that app is not installed, ContextRoute uses the regular source-app rule.
- If a link comes from an app with an enabled rule, ContextRoute opens it in the selected browser and profile.
- If no matching rule is available, the link opens in the selected fallback browser. During initial setup, ContextRoute uses the current macOS default browser. A browser selected manually stays selected after relaunch.
- As the default browser, ContextRoute also receives webpage Handoff from iPhone and iPad. These links use **Open in apps** and then the fallback browser, because Handoff does not provide a local source-app process for app-route matching.
- **Open in apps** includes built-in redirects from the Yojam catalog: Zoom, Telegram, Slack, Discord, Spotify, Apple Music, FaceTime, Maps, Microsoft Teams, Figma, Linear, Notion, WhatsApp, Signal, App Store, TestFlight, and Podcasts. Discord links are converted to `discord://` URLs.
- The sidebar has three sections: **App routes**, **Open in apps**, and **Settings**. Settings contains the fallback browser, theme, language, launch-at-login option, and import/export. The interface defaults to English; Russian and the system language are also available, along with system, light, and dark themes.
- Sidebar search finds individual settings, rules, and handler domains. Selecting a result opens the relevant section and scrolls to the matching item.
- In browsers that do not support profile selection, links open in the browser's regular profile.
- At launch, ContextRoute caches routing rules, app paths, selected-profile availability, and profile launch arguments. Link handling uses that cache instead of rereading settings, profile folders, or searching for apps. Profile launches run in a background queue.

Profile folders are detected automatically for browsers in the Yojam catalog: Chrome Stable/Beta/Canary, Brave Stable/Beta/Dev, Edge Stable/Beta, Vivaldi, Wavebox, Helium, Comet, Yandex Browser, Opera/Opera GX, Chromium, Firefox/Developer Edition/Nightly, and Zen. Chromium profiles are read from `Local State`; Firefox profiles are read from `profiles.ini`. For browsers without a compatible profile list, you can select the browser itself and ContextRoute will open it normally.

## Installation

1. Move `ContextRoute.app` to `/Applications` and open it. If macOS shows a warning, right-click the app in Finder and choose **Open**.
2. On first launch, **App routes** opens with a **Make default browser** button. The fallback browser is detected from the current macOS default browser; if detection fails, **Settings** opens so you can choose one manually.
3. In **App routes**, add a rule and choose the source app, browser, and profile. The app picker opens in `/Applications`; the profile-folder picker starts in the browser's automatically detected folder.
4. Profiles load automatically. The progress indicator and refresh button are to the right of the profile selector. The profile-folder path and its controls are directly below the profile list. If the browser uses a different data directory, click **Profile folder…** and choose the folder containing `Local State` (Chromium) or `profiles.ini` (Firefox), not an individual profile folder. **Use default folder** restores the browser's standard data directory. If loading fails, you can choose a folder right away and retry with the button beside the profile selector. The form content scrolls while its header and save buttons stay in place.
5. Click **Make default browser** and confirm the choice in macOS if prompted. Until ContextRoute is assigned to handle `http` and `https`, the button stays at the top of settings pages and **Make default browser…** remains in the app menu.
6. Opening the app normally shows the settings window. Launch-at-login and link handling run from the menu bar without opening a window. Turn on **Settings → Launch at login** to launch ContextRoute at sign-in. If macOS requires permission, **Open Login Items** opens the relevant system setting. macOS launches the assigned handler when a link needs processing, even if ContextRoute is not already running.

The app menu and menu-bar menu contain **Settings…** to open rules and settings. The menu-bar menu also has **About ContextRoute** and **Quit ContextRoute**. **About ContextRoute** opens the system window with the app version and author Sergey Bekharskiy.

While the settings or About window is open, the app menu, **File**, and **Window** menus are available, as is the Dock icon. The **Edit** and **View** menus are removed, and window tabs are disabled. `⌘W` closes the window; `⌘Q` quits the app. `⌘X`, `⌘C`, `⌘V`, and `⌘A` still work in text fields. After the last window closes, ContextRoute returns to the menu bar and continues handling links.

Selecting a profile is optional. If you leave **Use browser default** selected, the link opens in the destination browser as usual.

## Managing rules

- The switch on a rule temporarily disables it while keeping its browser and profile settings.
- You can undo deleting, editing, or replacing a rule; changing a handler or fallback browser; and importing settings with `⌘Z`. Redo with `⇧⌘Z`. After a rule change, **Undo** is also available on the App routes page. In text fields, these shortcuts undo and redo text edits. Rule history lasts until the app quits or settings are reloaded.
- If you select an app that already has a rule, the editor clearly warns that the existing rule will be replaced and asks you to confirm.
- **Check route…** accepts a link and source app, then explains the routing result. It uses the same logic as link handling and does not open the link.
- The routing cache updates when settings are saved, imported, undone, or redone. If a browser or profile is installed, removed, or moved while ContextRoute is running, refresh it with the toolbar's **Refresh** button. Bringing the app to the foreground does not rescan browsers or profiles.
- An unavailable browser or profile is marked in the rules list. If the route cannot be used, ContextRoute uses the fallback browser and shows a warning. Launch errors appear in settings; you can copy the link or try opening it in the fallback browser.
- **Settings → Import and export** transfers rules, handler states, and the fallback browser in a JSON file. Import replaces those settings after confirmation; theme, language, and launch-at-login stay local to the computer.

## Saving and recovery

Settings are saved atomically. The previous working version is kept as `config.backup.json` alongside the main file. If saving fails, the change is not applied and the editor stays open.

If the main file is damaged, the app offers to restore the backup. If there is no valid backup, you can retry reading the file or import settings. Before a confirmed restore or import, the damaged file is saved separately.

## Building from source

Xcode 27 is required. Open `ContextRoute.xcodeproj` or build the app with:

```sh
./Scripts/build-app.sh
```

The Xcode project targets macOS 27, so system interface elements use the current Liquid Glass appearance. The script builds a Release app, signs it with the locally installed **Developer ID Application** certificate using Hardened Runtime, and copies it to `ContextRoute.app`. The project is configured for Sergey Bekharskiy's Apple team (`DSP3NSS4L8`); use your own team and signing identity when building under another account.

GitHub Actions builds an unsigned artifact for pushes to `main`, pull requests, and manual runs. Pushing a `vMAJOR.MINOR.PATCH` tag starts the signed release workflow: it notarizes and staples the app, then publishes versioned and stable ZIP downloads. The same workflow can be started manually from `main` with a version number.

For signed GitHub releases, add these repository Actions secrets:

- `APPLE_DEVELOPER_ID_CERTIFICATE_BASE64` — base64-encoded Developer ID Application `.p12` certificate.
- `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD` — password used when exporting that `.p12` file.
- `APPLE_NOTARY_KEY_ID` — App Store Connect **Team API Key** ID. Individual API keys cannot authenticate with `notarytool`.
- `APPLE_NOTARY_ISSUER_ID` — App Store Connect API issuer ID.
- `APPLE_NOTARY_PRIVATE_KEY_BASE64` — base64-encoded `.p8` private key for the API key.

Set these in the repository's **Settings → Secrets and variables → Actions**. Do not put certificate or private-key contents in the repository.

Routing and profile-launch checks:

```sh
./Scripts/check-routing.sh
```

The script checks rule priorities, unavailable browsers and profiles, argument passing, and launch errors. Chrome or Safari must be installed to check browser availability. Launch processes are checked with temporary apps, without opening links in a real browser or changing user settings.

## Routing diagnostics

Routing timing logs are disabled by default. To enable them, quit any running instance and launch the app from the project directory with:

```sh
open ./ContextRoute.app --args --debug-routing
```

The flag enables timing logs in the macOS system log for that run only. It is not saved in preferences. Log entries contain routing stages and durations; URLs are not recorded.

## Data and limitations

- Settings are stored in `~/Library/Application Support/ContextRoute/config.json`.
- To list profiles, the app reads `Local State` or `profiles.ini` from the browser's data folder. macOS may separately ask for access to browser data; if access is denied, the profile list will not load. ContextRoute reads metadata and does not modify it. Read errors appear in the editor.
- Launching a browser and checking that a profile exists do not confirm that a page loaded: browsers provide no common API for confirming link delivery. ContextRoute reports system-open errors and nonzero process exits during the first 10 seconds after launch.
- The source app is determined from the app macOS reports with the link. If a link was copied or relayed through another app, macOS may report that intermediary as the source.
- A local build is Developer ID signed but is not notarized. GitHub release builds are notarized and stapled by the release workflow.
