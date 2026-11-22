# BobukKit

The name is a Ukrainian pun: **Бобук Кіт** — “Bobuk the Cat”. Bobuk is the
author's name, and Ukrainian **кіт** means “cat”. A toolkit with a cat in its name. :)

The shared library of the native bobuk-io apps (Ting, lowkey, Splash Finish, HAScS): their
window shell, panels, controls, system services, Homebrew updates and the release kit.
Canonical checkout: `~/GitHub/bobuk.io/BobukKit`. Requires macOS 14 and Swift 6.2.
**Before you write a window, a panel, a button style, a hotkey, a file store, a process runner
or an update flow in an app, find it in the catalog below.** If it is missing and two apps
need it, add it here, not to the app. Agents: read `AGENTS.md`.

## Catalog: task → component

| Task | Use | Product |
| --- | --- | --- |
| Any app window (Settings, Welcome, permissions, update progress, browser) | `ChromeWindow`: accent line, strip with close on the left, `body` for content; `setContent(view)` / `ChromeWindow.hosting(view)` for SwiftUI (no safe-area offset); `contentSize(forBody:)`; ⌘W closes and ⌘C/⌘V/⌘Z reach text fields even without an Edit menu | BobukUI |
| A close, back, reload… button of a window | `StripButton(glyph:label:)` in `ChromeWindow(leading:trailing:)` or `strip.addTrailing` | BobukUI |
| Show/close one window, remember its frame, release content on close | `HostedWindowController` (`prepare()` builds without showing, `sizesToFitContent`) | BobukUI |
| SwiftUI content that must close or read its own window | `.windowReference(WindowReference())` | BobukUI |
| A floating panel (launcher, inbox, prompt, HUD) | `BobukPanel(kind:)` with `onDismiss`, `onCommandKey`, `suspendDismissal()`; `swallowsOtherCommandKeys = false` when SwiftUI content has its own ⌘ shortcuts | BobukUI |
| ⌘C/⌘V/⌘Z in a non-activating panel, ⌘Q must not quit | built into `BobukPanel`; `EditCommand.classify` | BobukUI |
| Which screen and where a panel appears | `window.place(size:anchor:)`, `Screens.underPointer`, `PanelPlacement` | BobukUI / BobukCore |
| Grow a panel with its content, top edge fixed | `window.fitHeight(to:)`, `PanelPlacement.resize` | BobukUI / BobukCore |
| Line icons (close, back, lock, reload, plus, check, settings…) | `Glyph`, `GlyphView` (AppKit), `GlyphImage` (SwiftUI) | BobukUI |
| An icon action inside content (dismiss a card, remove a row) | `GlyphButton` (SwiftUI; square or `width:height:glyphSize:hoverFill:`, separate `help:`) | BobukUI |
| Picker rows, badges, search field, shortcut hints (+ optional Settings gear), panel frame | `PickerRow`, `PickerBadge`, `PickerSearchField`, `ShortcutFooter(..., onSettings:)`, `.pickerPanel`, `PickerSurfaceView` | BobukUI |
| Light/dark colors from hex, the shared amber palette | `NSColor.dynamic(light:dark:)`, `BobukColors`, `PickerPalette.bobukAmber` | BobukUI |
| App-wide Light/Dark/System setting | `AppearanceChoice` (`apply()`, `stored(in:key:)`) | BobukUI |
| Color themes: curated presets, custom panel/accent, derived WCAG tokens, live store & Settings UI | `RGB`, `ThemePreset`, `ThemeColors`, `ThemePaletteConfig`, `ThemeTokens`, `ThemeStore`, `ThemedSection`, `ThemeSettingsSection`, `ThemePreview`, `.themedSurface(_:)`, `ChromeWindow.bindTheme`, `BobukPanel.bindTheme` | BobukCore / BobukUI |
| Small bordered or accent button, mono caps label | `QuietButtonStyle(palette:prominent:)`, `MonoLabel` | BobukUI |
| A short message near the top of the screen | `ToastController` | BobukUI |
| Global hotkey (no Accessibility permission) | `GlobalHotkeyCenter(signature:)` | BobukSystem |
| Hotkey strings `option+shift+cmd+f`, key names, modifier taps | `Hotkey`, `KeyCodes`, `ModifierSet`, `ModifierTapDetector` | BobukCore |
| Named key codes instead of 53/36/126/43, layout-independent digits | `VirtualKey` | BobukCore |
| The Latin key of an event on a Russian/Ukrainian layout | `KeyTranslator.latin`, `KeyEquivalent.latin(of:)` | BobukSystem / BobukUI |
| Text typed on the wrong layout (ыфафкш → safari) | `KeyboardLayoutSwap.variants(of:)` | BobukCore |
| Fuzzy search in names and choices (1pwd, 1pvd → 1Password; vsc → Visual Studio Code; wrong layout) | `FuzzyQuery(query).match(text)` (`kind`, `score`, `positions`), `FuzzyMatcher.filter(_:matching:texts:)`, `AttributedString.highlighting(_:query:color:)` for matched letters | BobukCore / BobukUI |
| Only one shortcut recorder at a time, hotkeys off while recording | `HotkeyRecordingGate` | BobukSystem |
| Launch at login | `LoginItem` | BobukSystem |
| Accessibility permission | `AccessibilityPermission` | BobukSystem |
| Bring an accessory app to the front | `AppActivation.activate()` (never `activate(ignoringOtherApps:)`) | BobukSystem |
| Secrets | `KeychainItem(service:account:)` | BobukSystem |
| Reload when a file or a folder of files changes on disk | `FileWatcher(url:)`, `FileWatcher(folder:)` | BobukSystem |
| Config/support paths with one env override for tests (a file like `TING_CONFIG` or a folder like `SPLASH_FINISH_HOME`) | `AppPaths` (`config`, `file`, `dataFile`, `companion`) | BobukCore |
| One Codable value in a JSON file, explicit corrupt-file policy | `JSONFileStore` | BobukCore |
| Atomic writes that refuse symlinks; single-instance lock | `SafeFile.write`, `FileLock` | BobukCore |
| Most-recent-first history | `RecentList` | BobukCore |
| Run a program with time limit, output cap and cancel | `ChildProcess.run` | BobukCore |
| App ↔ command-line companion IPC | `MessagePortServer`, `MessagePortClient` (`sendTimeout`, `waitForServer(keepWaiting:)`) | BobukCore |
| The real `.app`, version, resource bundles without `Bundle.module` (also under `swift test`) | `AppBundle` | BobukCore |
| Logging | `BobukLog.logger("category")` | BobukCore |
| Sparkle or Homebrew updates, the brew progress window | `UpdateService.detect(app:makeSparkle:)`, `HomebrewLaunch` | BobukUpdates |
| Test folders, fake executables and `.app` bundles, isolated defaults | `TemporaryDirectory`, `IsolatedDefaults`, `VersionFile` | BobukTestSupport |
| Signing, notarization, GitHub release, appcast, cask, landing | `ReleaseKit/` (copied to `Scripts/release`) | scripts |

## Rules of the shell

- **Window controls live in the strip.** A window has exactly one close control: the strip's
  close button, `performClose`, ⌘W. Never draw an `xmark` button inside a window's content;
  never hand-roll a borderless window to look like `ChromeWindow`.
- **Windows** use a 2-point accent and a 20-point strip (`ChromeMetrics`). **Panels** use the
  picker surface: 14-point corners, a 3-point accent, a 1-point border (`PickerMetrics`). Panels
  have no close button: Esc, ⌘W and focus loss close them (`BobukPanel`).
- Colors come from the app (`PickerPalette`, `ChromeStyle`); the kit owns geometry and behavior.
  Identical colors across apps belong in `BobukColors`.
- Use native Buttons with accessibility labels; strip buttons are accessibility buttons with
  the shortcut in their label ("Close · ⌘W"). Decorative glyphs are hidden from accessibility.
- No automatic focus stealing, synthetic key events or animation beyond the chrome color fade.

## Products

| Product | Depends on | Notes |
| --- | --- | --- |
| `BobukCore` | Foundation | Safe in *Core targets and command-line tools; no AppKit. |
| `BobukSystem` | BobukCore, AppKit, Carbon, Security, ServiceManagement | |
| `BobukUI` | BobukCore, BobukSystem | |
| `BobukUpdates` | BobukCore, BobukSystem, BobukUI | Sparkle is **not** a dependency: apps that ship Sparkle pass a `SparkleUpdating` adapter. |
| `BobukTestSupport` | BobukCore | Test targets only; no assertions, works with XCTest and Swift Testing. |

## Local copies, not remote dependencies

Consumers use `.package(path: "Vendor/BobukKit")`. Builds need neither this checkout nor GitHub.
Commit the vendored snapshot with each app. Do not edit copies.

```sh
Scripts/sync.sh                 # sync the package and the release kit into all consumers
Scripts/sync.sh --check         # fail on missing/drifted copies; never write
Scripts/sync.sh /path/to/app    # explicit consumer, including a fresh checkout
swift test                      # kit tests (no real hotkeys, Keychain items or brew)
swift run BobukUIGallery /tmp/bobukkit-gallery   # offline renders of panels and windows
Scripts/test_sync.sh            # offline sync safety tests
ReleaseKit/release/test_kit.sh  # offline release kit tests
```

`consumers.txt` paths are relative to this checkout: Ting, lowkey, Splash Finish, HAScS.
Snapshot files are listed in `MANIFEST.sha256`; `.bobukkit-vendor` marks ownership. Sync
refuses an unmarked nonempty directory or a symlink rather than deleting app-owned files.
Cached `.build`/`.swiftpm` folders are preserved and excluded from drift comparison.
`Vendor/BobukKit/Scripts/check-vendor.sh` verifies snapshot hashes and runs the kit tests
without an upstream checkout; every app runs it as a release `EXTRA_TESTS` suite.

## Release kit

`ReleaseKit/release` and `ReleaseKit/entry` are the canonical release scripts of every app
(see `ReleaseKit/release/README.md`). `Scripts/sync.sh` copies them into `<app>/Scripts/release`
(marked by `.bobukkit-release`) and the five entry points (including `package_app.sh`) into `<app>/Scripts`, for apps with a
`release.env`. App facts (`release.env`, `version.env`, `Info.extra.plist`, `App.entitlements`, `homebrew_cask.rb`,
`check_bundle.swift`) stay in the app. `doctor.sh` checks the copies against `../BobukKit`.

## Changing the kit

Edit here, add or update tests, run `swift test`, the gallery and `Scripts/test_sync.sh`,
raise `VERSION`, sync **all** registered consumers, build and run their focused tests, look at
their actual windows, and commit the copies with the app changes. Run `--check` before
committing. No hosted CI or remote package resolution is required.

## License

0BSD, see LICENSE. No external runtime dependencies. The adapted release scripts in `ReleaseKit` keep their MIT license; see THIRD_PARTY_NOTICES.md.
