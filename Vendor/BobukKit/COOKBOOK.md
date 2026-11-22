# BobukKit Cookbook & API Reference for Agents

Self-contained recipes, verified API signatures, and gotchas for building native macOS apps with **BobukKit** (macOS 14+, Swift 6.2). This file travels inside every app at `Vendor/BobukKit/COOKBOOK.md`. Read this instead of hunting across `Sources/`.

> Rule reminder: never edit `Vendor/BobukKit` or `Scripts/release` inside an app. Edit `~/GitHub/bobuk.io/BobukKit`, test, raise `VERSION`, run `BobukKit/Scripts/sync.sh`, then `BobukKit/Scripts/sync.sh --check`.

---

## 1. Wiring an App (`Package.swift`)

Keep pure logic in `*Core` (Foundation only — no AppKit) so unit tests and CLI companions stay fast and headless.

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MyApp",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "Vendor/BobukKit")],
    targets: [
        .target(
            name: "MyAppCore",
            dependencies: [.product(name: "BobukCore", package: "BobukKit")]
        ),
        .executableTarget(
            name: "MyApp",
            dependencies: [
                "MyAppCore",
                .product(name: "BobukCore", package: "BobukKit"),
                .product(name: "BobukSystem", package: "BobukKit"),
                .product(name: "BobukUI", package: "BobukKit"),
                .product(name: "BobukUpdates", package: "BobukKit"), // optional
            ]
        ),
        .testTarget(
            name: "MyAppTests",
            dependencies: [
                "MyAppCore", "MyApp",
                .product(name: "BobukTestSupport", package: "BobukKit"),
            ]
        ),
    ]
)
```

To register a new consumer for `BobukKit/Scripts/sync.sh`: add its relative path to `BobukKit/consumers.txt`, add `release.env` and `version.env` in the app root, and run `BobukKit/Scripts/sync.sh`.

---

## 2. Color Themes (18 Presets, 10 Roles, Live Sync & Settings UI)

BobukKit ships 18 curated light + dark themes (`ThemePreset.all`: `amber`, `sage`, `ocean`, `clay`, `catppuccin`, `tokyo-night`, `kanagawa`, `everforest`, `rose-pine`, `flexoki`, `nord`, `dracula`, `gruvbox`, `solarized`, `one`, `ayu`, `monokai`, `github`) with 10 semantic color roles (`ThemeColorRole`: `panel`, `accent`, `ink`, `surface`, `muted`, `border`, `selection`, `link`, `success`, `danger`). Optional roles default to `nil` (WCAG auto-derived), so older 2-color JSON (`preset`, `panel`, `accent`) decodes cleanly.

### Option A: Per-app `UserDefaults`-backed `ThemeStore` (Splash Finish style)

```swift
import BobukCore
import BobukUI

@MainActor extension ThemeStore {
    static let appKeys = StorageKeys(appearance: "appTheme", palette: "appThemePalette")
    static let shared = ThemeStore(
        keys: appKeys,
        defaultAppearance: .dark,
        defaultPreset: .amber
    )
}
```

### Option B: Syncing `ThemeStore` with a JSON `Config` file (Ting style)

Set `appliesToApplication: false` if the app manages appearance per window, or `true` (default) for app-wide `NSApp.appearance`. Guard two-way sync with a re-entrancy flag:

```swift
let theme = ThemeStore(
    defaults: IsolatedDefaults.make().0, // or dedicated suite
    defaultAppearance: .dark,
    defaultPreset: .amber,
    appliesToApplication: false
)
// On config load:
theme.appearance = config.appearance
theme.palette = config.theme
// On NotificationCenter observer for ThemeStore.didChangeNotification:
config.appearance = theme.appearance
config.theme = theme.palette
```

### Option C: Page-tinted chrome without `ThemeStore` (lowkey style)

Re-export `BobukCore` from `*Core` (`@_exported import BobukCore`) and build tokens directly:

```swift
let normal = ThemeTokens(colors: colors)
let tinted = ThemeTokens(tint: pageRGB, colors: colors) // panel = tint, accent from palette, isTinted = true
```

### Reading colors from `ThemeTokens` & `ThemeStore`

| Role | `BobukCore` (`RGB`) | `BobukUI` (`Color`) | `BobukUI` (`NSColor`) |
| --- | --- | --- | --- |
| Panel background | `tokens.panel` | `tokens.panelColor` | `tokens.panelNSColor` |
| Elevated card / field | `tokens.elevated`, `tokens.field` | `tokens.elevatedColor`, `tokens.fieldColor` | `tokens.elevatedNSColor`, `tokens.fieldNSColor` |
| Primary text | `tokens.ink` | `tokens.inkColor` | `tokens.inkNSColor` |
| Secondary text | `tokens.muted` | `tokens.mutedColor` | `tokens.mutedNSColor` |
| Accent | `tokens.accent` | `tokens.accentColor` | `tokens.accentNSColor` |
| Text on accent (keycaps/badges) | `tokens.keyInk` | `tokens.keyInkColor` | `tokens.keyInkNSColor` |
| Borders & hairlines | `tokens.line`, `tokens.stroke` | `tokens.lineColor`, `tokens.strokeColor` | `tokens.lineNSColor`, `tokens.strokeNSColor` |
| Selected row fill | `tokens.selection` | `tokens.selectionColor` | `tokens.selectionNSColor` |
| Hover fill | `tokens.hover` | `tokens.hoverColor` | `tokens.hoverNSColor` |
| Link text | `tokens.link` | `tokens.linkColor` | `tokens.linkNSColor` |
| Success / Danger | `tokens.success`, `tokens.danger` | `tokens.successColor`, `tokens.dangerColor` | `tokens.successNSColor`, `tokens.dangerNSColor` |
| Soft status badges | `tokens.successSurface`, `tokens.accentSurface` | `tokens.successSurfaceColor`, `tokens.accentSurfaceColor` | — |
| Contrast checks | `tokens.lowAccentContrast`, `tokens.lowInkContrast` | — | — |
| Picker palette | — | — | `tokens.pickerPalette(increasedContrast: false)` (**method**) or `theme.pickerPalette` (**property**) |

### Settings UI: choose the right component!

- **Card-style Settings window (no `Form`):** use `ThemeSettingsSection(theme:)` + `ThemedSection("General", tokens:)` + `.themedSurface(theme)`.
- **Grouped macOS `Form` Settings window (like Ting):** use `ThemeSettingsFormRows(theme:)` inside `Form { Section("Appearance") { ThemeSettingsFormRows(theme: theme) } }.formStyle(.grouped)`.
- **Custom Settings pane (like lowkey's 5-mode Tint/Page/System/Light/Dark):** compose `ThemeSwatchStrip(tokens:)` and `ThemePreview(tokens:)` directly.

> **Never put `ThemeSettingsSection` inside a SwiftUI `Form`**, and **never wrap a fixed-size `ChromeWindow` root view in a bare `ScrollView`** (macOS offscreen `cacheDisplay` renders a root `ScrollView` blank). Instead, resize the `ChromeWindow` height dynamically via `GeometryReader` when `More colors` expands (see Recipe 3).

---

## 3. Windows (`ChromeWindow` + `HostedWindowController`)

Every standard window (Settings, Welcome, Integrations, Permissions, Browser) is a `ChromeWindow`. Controls live in the top `strip`; **never** draw an `xmark` close button inside content.

```swift
import AppKit
import BobukUI
import SwiftUI

let settingsController = HostedWindowController(
    frameName: "Settings",
    window: { [unowned self] in
        let size = ChromeMetrics.windowSize(forBody: NSSize(width: 480, height: 590))
        let win = ChromeWindow(
            contentRect: NSRect(origin: .zero, size: size),
            theme: .shared,
            resizable: false,
            showsTitle: true
        )
        win.title = "Settings"
        return win
    },
    rootView: { [unowned self] in
        SettingsView(theme: .shared, onBodyHeight: { [weak self] h in
            self?.resizeSettings(bodyHeight: h)
        })
    }
)
```

Dynamic height resize (keeps the window's top edge pinned when `More colors` opens/closes):

```swift
private func resizeSettings(bodyHeight: CGFloat) {
    guard bodyHeight > 100, let win = settingsController.window as? ChromeWindow else { return }
    let target = win.contentSize(forBody: NSSize(width: 480, height: ceil(bodyHeight)))
    let current = win.frame
    let delta = target.height - win.contentRect(forFrameRect: current).height
    guard abs(delta) > 1 else { return }
    let next = NSRect(x: current.origin.x, y: current.origin.y - delta,
                      width: current.width, height: current.height + delta)
    win.setFrame(next, display: true, animate: win.isVisible)
}
```

Key `ChromeWindow` rules:
- Always host SwiftUI via `window.setContent(view)` or `ChromeWindow.hosting(view)` (`safeAreaRegions = []` removes the 9pt hidden-titlebar inset).
- Add window controls with `StripButton(glyph: .reload, label: "Reload · ⌘R") { _ in ... }` passed to `leading:`/`trailing:` or `strip.addTrailing(_:)`.
- `ChromeWindow(theme:)` automatically calls `bindTheme(theme)`, keeping `chromeStyle`, `accentBar`, `strip`, `separator`, and `appearance` live-synced.
- If the app's File menu handles ⌘W (e.g., hiding vs closing), set `closesOnCommandW = false`. If hosting a `WKWebView` with a live Edit menu, set `routesEditCommands = false`.
- Inside SwiftUI content that needs to close its own window, attach `.windowReference(ref)` and call `ref.close()`.

---

## 4. Floating Panels, Pickers & Fuzzy Search (`BobukPanel` + `Picker*`)

Use `BobukPanel(kind:)` instead of subclassing `NSPanel`:
- `.floating` — non-activating panel (inbox, launcher): never steals focus from the previous app.
- `.prompt` — activating input prompt (address bar, quick input): dismisses on resign-key, deactivation, Esc, ⌘W.
- `.hud` — non-key HUD/toast overlay (`canBecomeKey == false`).

```swift
let panel = BobukPanel(kind: .floating)
panel.bindTheme(.shared)
panel.swallowsOtherCommandKeys = false // allow SwiftUI ⌘ shortcuts if needed
panel.onDismiss = { reason in /* .escape, .commandW, .resignKey, .appDeactivated, .programmatic */ }
panel.onCommandKey = { event, command in
    if KeyEquivalent.isCommand(event, latin: ",") {
        openSettings()
        return true
    }
    return false
}
```

Placement & growing top-anchored:

```swift
panel.place(size: NSSize(width: 460, height: 320), anchor: .upper(fraction: 0.22, minimum: 48))
panel.fitHeight(to: contentView, width: 460)
// Or pure math in *Core:
// PanelPlacement.place(size:remembered:screens:active:anchor:)
// PanelPlacement.resize(frame, toHeight:keepingTopIn:)
```

Standard picker SwiftUI body (matches Ting, lowkey, Splash Finish):

```swift
let palette = theme.pickerPalette
let query = FuzzyQuery(searchText) // supports Cyrillic↔Latin swap & typos
let badgeWidth = PickerMetrics.badgeWidth(for: items.map(\.badge))

VStack(alignment: .leading, spacing: 0) {
    PickerSearchField(text: $searchText, placeholder: "Search…",
                      accessibilityLabel: "Search items", palette: palette)
        .padding(16)
    Divider()
    VStack(spacing: 0) {
        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
            PickerRow(selected: index == selectedIndex, palette: palette) {
                HStack(spacing: PickerMetrics.columnSpacing) {
                    PickerBadge(item.badge, width: badgeWidth, palette: palette)
                    Text(AttributedString.highlighting(item.title, query: searchText,
                                                       color: Color(nsColor: palette.accent)))
                        .font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
    }
    .padding(.horizontal, 6).padding(.vertical, 4)
    Divider()
    ShortcutFooter(
        [.init("↑↓", "select"), .init("↩", "open"), .init("esc", "close")],
        palette: palette,
        onSettings: openSettings // built-in bottom-right gear button!
    )
    .padding(.horizontal, 16).padding(.vertical, 10)
}
.foregroundStyle(Color(nsColor: palette.text))
.padding(.top, PickerMetrics.accentHeight)
.pickerPanel(palette: palette)
```

Useful picker helpers:
- `PickerSelection.move(selected, by: 1, count: results.count, allowsEmpty: false)` for ↑/↓ wrap-safe movement.
- `FuzzyMatcher.filter(items, matching: query, texts: { [$0.title, $0.alias] })` for ranked filtering.
- `QuietButtonStyle(palette: palette, prominent: false, height: 28)` for compact bordered or accent buttons.
- `GlyphButton(.close, label: "Dismiss", help: "Dismiss", palette: palette) { ... }` for inline icon actions.
- `ToastController(theme: .shared)` for transient top-of-screen messages.

---

## 5. Global Hotkeys & Cyrillic-Safe Keys (`BobukSystem` + `BobukCore`)

```swift
import BobukCore
import BobukSystem

let hotkeys = GlobalHotkeyCenter(signature: OSType("MYAP"))
if let hotkey = Hotkey(string: "option+cmd+s") {
    let status = hotkeys.register(hotkey, id: 1, repeats: false) { _ in
        showPanel()
    }
    if case .failed(let reason) = status {
        log.error("Hotkey unavailable: \(reason, privacy: .public)")
    }
}
```

- Use `VirtualKey` constants (`VirtualKey.escape`, `VirtualKey.returnKey`, `VirtualKey.up`, `VirtualKey.down`, `VirtualKey.digit(keyCode)`) — never raw numbers like `53` or `36`.
- Use `KeyEquivalent.latin(of: event)` or `KeyEquivalent.isCommand(event, latin: ",")` so shortcuts work identically on Russian/Ukrainian layouts.
- Use `KeyboardLayoutSwap.variants(of: text)` when matching user queries typed on the wrong layout.
- Use `HotkeyRecordingGate` when Settings has shortcut recorders so global hotkeys pause while recording and only one recorder runs at a time.
- In unit tests, pass a mock `register:` closure to `GlobalHotkeyCenter(signature:register:)` — **never** register real Carbon global hotkeys in tests.

---

## 6. Paths, Persistence, Secrets, Processes & IPC

### Isolated paths (required for tests & demo runs!)

```swift
let paths = AppPaths(
    supportFolder: "MyApp",             // ~/Library/Application Support/MyApp
    configFolder: "myapp",              // ~/.config/myapp/config.json
    overrideVariable: "MYAPP_CONFIG",   // file override (like TING_CONFIG)
    folderOverrideVariable: "MYAPP_HOME"// or folder override (like SPLASH_FINISH_HOME)
)
let configURL = paths.config
let historyURL = paths.dataFile("history.json")
```

### Safe JSON storage, atomic writes & locks

```swift
let store = JSONFileStore<MyConfig>(url: paths.config, policy: .refuseWrites) { MyConfig() }
switch store.load() {
case .loaded(let config): ...
case .missing(let fallback): ...
case .corrupt(let error): ... // refuses to overwrite user's corrupt file
}
try store.save(config) // atomic, refuses symlinks via SafeFile.write
let lock = try FileLock(url: paths.file("app.lock"), nonblocking: true)
```

### System utilities

- **Keychain:** `let item = KeychainItem(service: "io.bobuk.myapp.v1", account: "token")`; `try item.write(secret)`, `try item.readString()`, `try item.readCodable(Creds.self)`.
- **File watching:** `let watcher = FileWatcher(url: paths.config) { reload() }` (or `FileWatcher(folder:)`). Handles atomic saves; call `watcher.stop()` on teardown.
- **Launch at login:** `LoginItem.isEnabled`, `try LoginItem.set(true)`.
- **Accessibility:** `AccessibilityPermission.isTrusted`, `AccessibilityPermission.openSettings()`.
- **App activation:** `AppActivation.activate()` (never `NSApp.activate(ignoringOtherApps: true)`), `AppActivation.becomeAccessory()`.
- **Bundled resources:** `AppBundle.resourceBundle(named: "MyApp_MyApp")` — **never** use `Bundle.module` (crashes when moved into `Contents/Resources` of a packaged `.app`!).
- **Logging:** `let log = BobukLog.logger("app")`.
- **Subprocess with timeout & output cap:** `let outcome = await ChildProcess.run(ChildProcessRequest(executable: "/usr/bin/env", arguments: ["python3", "..."], timeLimit: 30))`.
- **App ↔ CLI IPC:** `MessagePortServer(name: MessagePortServer.name(prefix: "io.bobuk.myapp")) { id, data in ... }` and `MessagePortClient.send(data, to: name)`.

---

## 7. Updates: Sparkle + Homebrew (`BobukUpdates`)

Apps never link Sparkle into BobukKit directly; pass a thin `SparkleUpdating` adapter if the app ships Sparkle. Homebrew copies automatically disable Sparkle and run `brew upgrade --cask --greedy` in a themed progress window.

```swift
let identity = AppUpdateIdentity(
    displayName: "MyApp",
    executableName: "MyApp",
    cask: HomebrewCask(name: "myapp", appBundleName: "MyApp.app"),
    bundleIdentifier: "io.bobuk.myapp",
    keptNotice: "Your settings and data are kept."
)

// Early in main() / applicationDidFinishLaunching, before normal UI:
if HomebrewLaunch.runViewerIfRequested(app: identity, theme: .shared) { return }

let updates = UpdateService.detect(app: identity, theme: .shared) {
    MySparkleAdapter() // only invoked for non-Homebrew packaged copies with a feed
}
// After launch:
HomebrewLaunch.showResultIfRequested(app: identity, theme: .shared)
// In menu:
if let title = updates.menuTitle { /* menu item -> updates.checkForUpdates() */ }
```

---

## 8. Testing & Visual Verification (`BobukTestSupport`)

```swift
import BobukTestSupport
import Testing

@MainActor @Suite(.serialized) struct MyTests {
    @Test func isolatedRoundTrip() throws {
        let dir = try TemporaryDirectory(prefix: "myapp-test")
        defer { dir.remove() }
        let (defaults, suite) = IsolatedDefaults.make()
        defer { IsolatedDefaults.remove(suite) }

        let theme = ThemeStore(defaults: defaults, defaultAppearance: .dark,
                               defaultPreset: .amber, appliesToApplication: false)
        // never activate NSApp, register real hotkeys, or open visible windows
    }
}
```

### Rendering offscreen PNG previews in tests

Support `BOBUKKIT_PREVIEW_DIR` so agents can visually inspect UI changes without opening windows on screen:

```swift
if let dir = ProcessInfo.processInfo.environment["BOBUKKIT_PREVIEW_DIR"] {
    let url = URL(fileURLWithPath: dir, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // For ChromeWindow with VStack body:
    content.layoutSubtreeIfNeeded()
    content.displayIfNeeded()
    let bmp = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
    content.cacheDisplay(in: content.bounds, to: bmp)
    try #require(bmp.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("preview.png"))
}
```

- For grouped `Form` views (`formStyle(.grouped)`), capture `hosting` (`NSHostingView`) after `try await Task.sleep(for: .milliseconds(80))`.
- For non-Form `ChromeWindow` views, avoid wrapping the entire body in a root `ScrollView` (see Pitfalls below).

---

## 9. Text-only ACP Chat (`ACPAgentPreset` + `ACPClient` + `AgentChatView`)

BobukKit provides a reusable text-only chat over **ACP v1** (JSON-RPC 2.0 over stdio):
- `BobukCore`: `ACPAgentPreset` (built-in presets for **Antigravity**, **Codex**, **Claude**, **Pi**, **Kimi**, **Gemini**, **OpenCode**), `ACPProcessIsolation`, `ACPLaunchConfiguration`, `ACPClient`, `ACPModels`, `ACPError`.
- `BobukUI`: `AgentChatSession` (`@MainActor @Observable`) and `AgentChatView` (minimalist editorial thread, centered empty state with clickable `starters`, unified floating composer with `Agent · Model` switcher menu, optional sandbox pill, `⌘↩` send, `esc` stop, and inline error/recovery banner).

### Built-in ACP agent presets (`ACPAgentPreset.all`)

| Preset | Executable(s) | Arguments | Notes |
| --- | --- | --- | --- |
| `.antigravity` | `agy` | `acp --disable-telemetry --include-default-customizations=false` (`+--sandbox`) | Built-in ACP; requires model catalog |
| `.codex` | `codex-acp` | *(none)* | `npm i -g @agentclientprotocol/codex-acp` |
| `.claude` | `claude-agent-acp`, `claude-code-acp` | *(none)* | `npm i -g @agentclientprotocol/claude-agent-acp` |
| `.pi` | `pi-acp` | *(none)* | `npm i -g pi-acp` |
| `.kimi` | `kimi` | `acp` | Built-in ACP (`kimi acp --login`) |
| `.gemini` | `gemini` | `--acp` | Built-in ACP (`@google/gemini-cli`) |
| `.opencode` | `opencode` | `acp` | Built-in ACP (`brew install opencode`) |

### Step 1: Auto-detect available agents & launch in a working folder

Use `ACPAgentPreset.detectInstalled()` / `ACPAgentPreset.preferredAvailable()` to discover which CLI agents are installed on the user's Mac (`~/.local/bin`, `/opt/homebrew/bin`, `mise`, `volta`, `PATH`, or `BOBUK_ACP_<ID>_PATH`).

`ACPAgentPreset.launch(in:sandboxed:access:clientName:)` opens the agent in `directory` (`cwd`) with network access enabled:
- `access: .workspace(allowWrite: true, autoApproveTools: true)` (default) advertises ACP `fs/read_text_file` & `fs/write_text_file` scoped to `directory` (+ `additionalRoots`), allows tool calls, and streams active tool status to `session.activeTool`.
- `access: .textOnly` disables all ACP file/tool capabilities and disconnects on unexpected tool execution.
- `sandboxed: true` (default) wraps the process in `/usr/bin/sandbox-exec`, allowing reads/writes in `directory` and the agent's own state dir while blocking unrelated user folders (`~/Downloads`, `~/Desktop`, `~/Documents`, `/Volumes`, `/Network`). Never falls back to direct launch.
- `sandboxed: false` launches `.unrestricted` with the user's OS privileges.

```swift
let available = ACPAgentPreset.detectInstalled()
let agent = ACPAgentPreset.preferredAvailable()
let launch = try agent.launch(
    in: projectFolderURL,
    sandboxed: options.sandboxed,
    access: .workspace(allowWrite: true, autoApproveTools: true),
    clientName: "myapp"
)
let client = ACPClient(launch: launch)
```

For a custom agent or custom sandbox policy, construct `ACPLaunchConfiguration` directly:

```swift
import BobukCore
import Foundation

func makeAgentLaunch(
    agentURL: URL,
    workspace: URL,
    sandboxed: Bool,
    sandboxProfile: String
) throws -> ACPLaunchConfiguration {
    let isolation: ACPProcessIsolation = sandboxed
        ? .sandboxed(launcher: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                     arguments: ["-p", sandboxProfile])
        : .unrestricted

    var args = ["acp", "--disable-telemetry"]
    if sandboxed { args.append("--sandbox") }

    return ACPLaunchConfiguration(
        executable: agentURL,
        arguments: args,
        directory: workspace,
        environment: [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "TMPDIR": workspace.path + "/",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
        ],
        clientName: "myapp",
        isolation: isolation
    )
}
```

### Step 2: Wire `AgentChatSession` and `AgentChatView` in a `ChromeWindow`

```swift
import AppKit
import BobukCore
import BobukUI
import SwiftUI

@MainActor @Observable final class ChatOptions {
    var agent: ACPAgentPreset = .antigravity
    var sandboxed = true
}

struct AssistantView: View {
    let chat: AgentChatSession
    let theme: ThemeStore
    @Bindable var options: ChatOptions
    var onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AgentChatView(
                session: chat,
                agent: options.agent.name,
                intro: "Text-only session without file access.",
                emptyTitle: "How can I help?",
                placeholder: "Message…",
                starters: [
                    "Draft a rule for PDF invoices",
                    "Suggest an initial folder structure",
                ],
                sandboxed: $options.sandboxed,      // omit to hide the sandbox toggle
                agents: ACPAgentPreset.all,         // auto-detects Available vs Not Installed
                selectedAgent: $options.agent,
                workingDirectory: projectFolderURL, // shows active folder badge in composer
                tokens: theme.tokens                // or pass `palette: theme.pickerPalette`
            )

            // React to a complete, validated reply without mutating anything automatically:
            if let reply = chat.lastReply {
                // Parse and preview app-specific proposals here.
                EmptyView().onAppear { _ = reply }
            }

            Divider()
            ShortcutFooter(
                [.init("⌘↩", "send"), .init("esc", "stop")],
                palette: theme.pickerPalette,
                settingsHelp: "Settings · ⌘,",
                onSettings: onSettings
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .themedSurface(theme)
    }
}
```

### Step 3: Manage lifecycle in `AppDelegate`

Create the session lazily, disconnect when the window closes (releasing the child process and clearing transcript/draft), and `await chat.shutdown()` before quitting:

```swift
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let theme = ThemeStore.shared
    private let options = ChatOptions()
    private var window: ChromeWindow?
    private var terminating = false

    private lazy var chat = AgentChatSession(
        makeClient: { [weak self] in
            guard let self else { throw ACPError.disconnected }
            let launch = try makeAgentLaunch(
                agentURL: agentBinaryURL,
                workspace: privateScratchDir,
                sandboxed: self.options.sandboxed,
                sandboxProfile: mySandboxProfile
            )
            return ACPClient(launch: launch)
        },
        preparePrompt: { userText in
            "Reply with plain text and an optional JSON block.\n\n\(userText)"
        },
        displayReply: { rawReply in
            // Optional: strip wire JSON from the visible bubble while keeping `chat.lastReply` intact.
            stripJSONBlock(from: rawReply)
        },
        // Optional: block Send and show a Reconnect banner if the agent returns no model catalog.
        missingModelsMessage: "The agent did not return any models. Check your connection, then reconnect."
    )

    func openChatWindow() {
        if window == nil {
            let size = ChromeMetrics.windowSize(forBody: NSSize(width: 480, height: 560))
            let win = ChromeWindow(contentRect: NSRect(origin: .zero, size: size), theme: theme, showsTitle: true)
            win.title = "Assistant"
            win.delegate = self
            win.setContent(AssistantView(chat: chat, theme: theme, options: options, onSettings: { /* ... */ }))
            win.center()
            window = win
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        chat.disconnect()
        options.sandboxed = true // restore safe default
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            await chat.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
```

### Headless one-shot call (no UI required, explicit `model` & `effort`)

Works in pure `*Core` targets, background workers, or CLI tools — no AppKit/SwiftUI needed. `model` matches exact ID, display name, or case-insensitive substring; `effort` maps to the agent's ACP `thought_level` / `reasoning_effort` option (`"low"`, `"medium"`, `"high"`, `"xhigh"`, `"max"`):

```swift
import BobukCore

let reply = try await ACPAgentPreset.antigravity.ask(
    "Classify fiber_2026-03.pdf into one folder.",
    in: archiveFolderURL,
    options: ACPPromptOptions(
        model: "gemini-3.8-flash",
        effort: "low",
        sandboxed: true,
        access: .textOnly // or .workspace(allowWrite: false) to let the agent inspect files
    ),
    clientName: "myapp"
) { chunk in
    // Optional streaming callback
}
print(reply.text, reply.model ?? "", reply.effort ?? "")

// Or auto-pick the first installed agent on the user's Mac:
let quick = try await ACPAgentPreset.ask(
    "Summarize README.md",
    in: projectFolderURL,
    options: ACPPromptOptions(effort: "medium", access: .workspace(allowWrite: false)),
    clientName: "myapp"
)
```

For UI sessions (`AgentChatSession`), pass `initialModel:` and `initialEffort:` to pre-select them automatically on connect.

### Rules & security boundary

- **Markdown & raw copy:** `AgentChatView` renders Markdown (headings, lists, blockquotes, inline styles, and fenced code blocks with a per-block Copy button). Every message supports text selection, right-click **Copy Markdown**, and **double-click** to copy the exact raw Markdown as plain text (`NSPasteboard.PasteboardType.string`, never RTF).
- **No credentials in BobukKit:** the local CLI must already be authenticated in Terminal; `ACPClient` maps `-32000` auth errors to `ACPError.authenticationRequired`.
- **Complete replies only:** `chat.lastReply` is populated only after `stopReason == "end_turn"` with non-empty text, never on cancelled or truncated turns. Always validate it before deriving app actions, and never execute it as code.
- **Process boundary vs. ACP callbacks:** `ACPClient` advertises empty `clientCapabilities`, attaches no MCP servers, rejects `session/request_permission` and unknown server methods, and disconnects on unexpected `tool_call` execution (`ACPError.unexpectedTool`). That does **not** restrict the agent's own built-in tools — the caller owns process confinement, working directory, and environment. Keep ACP policy and process isolation separate.
- **Offline tests:** pass a small `/bin/bash` fixture script to `ACPLaunchConfiguration(..., isolation: .unrestricted)` (see `Tests/BobukCoreTests/ACPClientTests.swift` and `Tests/BobukUITests/AgentChatSessionTests.swift`). Never call live models or real credentials in tests.

---

## 10. Known Pitfalls & Agent Checklist

| Pitfall | Fix |
| --- | --- |
| `tokens.pickerPalette` fails to compile with *"function produces expected type"* | `ThemeTokens.pickerPalette(increasedContrast: Bool = false)` is a **method** (`tokens.pickerPalette()`); `ThemeStore.pickerPalette` is a **property**. |
| `SettingsView` wrapped in a root `ScrollView` renders blank/transparent in `cacheDisplay` | Don't use a root `ScrollView` on a fixed `ChromeWindow`. Use a `VStack` + `.fixedSize(horizontal: false, vertical: true)` and dynamically resize the `ChromeWindow` height via `GeometryReader` (see Recipe 3). |
| `ThemeSettingsSection` inside `Form` renders broken/white | Use `ThemeSettingsFormRows(theme:)` inside grouped `Form`, and `ThemeSettingsSection(theme:)` inside non-Form `VStack` cards. |
| `NSApp` crashes with `Unexpectedly found nil` in isolated unit tests | Use `NSApplication.shared` (not `NSApp`) inside lazy singletons and test helpers. |
| Swift 6 actor error on default parameter `theme: ThemeStore = .shared` | Accept `theme: ThemeStore? = nil` and resolve `theme ?? .shared` inside the `@MainActor` body. |
| `SIGSEGV` (`signal 11`) in consumer tests after changing a public struct/class in BobukKit | Run `swift package clean` in the consumer app. **Warning:** this also deletes `.build/sparkle-tools/bin`; before running `Scripts/release/doctor.sh`, restore it from `.build/artifacts/sparkle/Sparkle/bin`. |
| `swift build` / `swift test` fails in sandbox writing `/var/folders/.../ModuleCache` | Pass `CLANG_MODULE_CACHE_PATH=/tmp/cc-<app> SWIFT_MODULE_CACHE_PATH=/tmp/sc-<app> swift test --disable-sandbox`. |
| `Bundle.module` crashes inside a packaged `.app` | Use `AppBundle.resourceBundle(named:)` — works in both `swift test` and `Contents/Resources`. |
| Name collision if a legacy app still defines `RGB` or `ThemeTokens` | Migrate `*Core` to `@_exported import BobukCore` and delete duplicate definitions (as in lowkey). |
| Drifted vendor copy fails release `doctor.sh` | Always edit `~/GitHub/bobuk.io/BobukKit`, run `swift test` + `Scripts/test_sync.sh`, bump `VERSION`, run `Scripts/sync.sh` and `Scripts/sync.sh --check`, then commit every consumer. |
