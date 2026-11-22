# BobukKit rules for agents

BobukKit is the shared library of the native bobuk-io apps. It travels into every app as
`Vendor/BobukKit` (a read-only snapshot) and its release kit as `Scripts/release`.

- **Look here first.** Before writing a window, panel, close/back button, icon, button style,
  palette helper, theme UI, hotkey, key-code table, layout swap, file store, safe write, process
  runner, Keychain access, login item, IPC, Homebrew/Sparkle update or test helper in an app, find
  it in `README.md` (catalog) and read **`COOKBOOK.md`** (copy-pasteable recipes, exact API
  signatures and known pitfalls; also vendored at `Vendor/BobukKit/COOKBOOK.md` in every app). Use
  it. If it almost fits, extend the kit; do not fork it in the app.
- **Never edit `Vendor/BobukKit` or `Scripts/release` in an app.** Change the canonical checkout
  `~/GitHub/bobuk.io/BobukKit`, then run `Scripts/sync.sh` and `Scripts/sync.sh --check`.
- **Windows:** `ChromeWindow`. Close and other window controls are `StripButton`s in its strip.
  A button with an `xmark`/`×` inside window content that closes the window is a bug.
- **Panels:** `BobukPanel(kind:)`. It already closes on focus loss, Esc and ⌘W, routes
  ⌘C/⌘V/⌘X/⌘A/⌘Z by the Latin layout and swallows ⌘Q. Customize through `onDismiss`,
  `onCommandKey` and `suspendDismissal()`/`resumeDismissal()`, not by subclassing `NSPanel` again.
- **Placement:** `window.place(size:anchor:)` on `Screens.underPointer`; no hand-written
  `NSScreen.screens.first { NSMouseInRect… }`.
- **Keys:** `VirtualKey` names, not magic numbers; `KeyEquivalent.latin(of:)` for ⌘ shortcuts on
  Cyrillic layouts.
- **Kit code is generic.** No app names, bundle IDs, colors of one app or strings of one app in
  the kit; pass them as parameters (`AppUpdateIdentity`, `PickerPalette`, `ChromeStyle`).
- **Tests:** every kit change has tests in `Tests/`. Tests never register real global hotkeys,
  write real Keychain items, run real `brew`, activate the app or show windows on screen.
- After a kit change: `swift test`, `swift run BobukUIGallery <dir>` and look at the PNGs,
  `Scripts/test_sync.sh`, `ReleaseKit/release/test_kit.sh` for release changes, raise `VERSION`,
  sync all consumers, build and test each app.
- Keep documentation in English. Code is 0BSD; the release scripts keep their MIT attribution
  in the apps' `THIRD_PARTY_NOTICES.md`.
