import AppKit
import SwiftUI
import BobukCore
import BobukSystem
import BobukUI
import BobukUpdates
import OSLog
import SplashFinishCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var model: AppModel!
    private var panel: SplashPanel!
    private var statusItem: NSStatusItem!
    private var unsnoozeMenuItem: NSMenuItem?
    private var indicatedSnoozeDeadline: Date?
    private var appLock: FileLock?
    private var panelSize = CGSize(width: 470, height: 350)
    private var integrationsWindow: HostedWindowController!
    private var settingsWindow: HostedWindowController!
    /// ⌥⌘S, matching the "Show Inbox" menu item. Carbon needs no Accessibility permission.
    private let hotkeys = GlobalHotkeyCenter(signature: OSType(fourCharacterCode: "sFHK"))
    private let log = BobukLog.logger("app")
    private var pendingURLs = [URL]()
    private var observers = [NSObjectProtocol]()
    /// Programmatic frame changes also post didMove; only user drags are remembered.
    private var isPlacingPanel = false
    private static let panelCornerKey = "panelTopLeft"

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ThemeStore.splash.apply()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            appLock = try FileLock(url: AppPaths.splashFinish().file("app.lock"), nonblocking: true,
                                   busyMessage: Splash.busyMessage)
        } catch { NSApp.terminate(nil); return }
        model = AppModel()
        panel = SplashPanel(size: panelSize)
        panel.bindTheme(.splash)
        panel.onKeyAction = { [weak self] action in self?.handleKey(action) ?? false }
        panel.contentView = NSHostingView(rootView: PanelView(model: model, theme: .splash,
            onOpen: { [weak self] event in
                guard let self else { return }
                self.model.openSource(event)
            }, onSize: { [weak self] size in
                DispatchQueue.main.async { self?.resize(to: size) }
            }, onSettings: { [weak self] in
                self?.showSettings()
            }))
        model.onChange = { [weak self] reveal in self?.update(reveal: reveal) }
        _ = UpdateService.shared
        registerHotkey()
        makeWindows()
        makeMenu()
        HomebrewLaunch.showResultIfRequested(app: .splashFinish, theme: .splash)
        update(reveal: model.revealsAtLaunch)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.offerIntegrationUpdates() }
        let urls = pendingURLs; pendingURLs.removeAll()
        urls.forEach(handle)
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.model.isSnoozed, !self.model.items.isEmpty else { return }
                self.model.show()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionPanel() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberPanelPosition() }
        })
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard model != nil else { pendingURLs.append(contentsOf: urls); return }
        urls.forEach(handle)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model?.reopen(); return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        model?.flush()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
    private func handle(_ url: URL) {
        guard url.scheme == DeepLink.scheme else { return }
        switch url.host {
        case "event":
            do { model.receive(try DeepLink.parse(url)) } catch { model.report(error) }
        case "question":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if items.count == 1, items[0].name == "id", let id = items[0].value { model.openQuestion(id: id) }
        case "show": model.show()
        case "snooze": model.snooze()
        case "clear": model.clear()
        default: model.report(EventError.invalid("Unknown Splash Finish URL command"))
        }
    }
    /// A failure (another app owns ⌥⌘S) is not fatal: the menu item stays and the app is fully usable.
    private func registerHotkey() {
        guard let hotkey = Hotkey(string: "option+cmd+s") else { return }
        let status = hotkeys.register(hotkey, id: 1, repeats: false) { [weak self] _ in self?.model.show() }
        if case .failed(let reason) = status { log.error("Global shortcut unavailable: \(reason, privacy: .public)") }
    }
    /// The panel keeps the corner the user dragged it to, as long as that corner is
    /// still on a connected screen; otherwise it returns to the active screen.
    private var rememberedPanelCorner: CGPoint? {
        guard let values = UserDefaults.standard.array(forKey: Self.panelCornerKey) as? [Double], values.count == 2,
              values.allSatisfy(\.isFinite) else { return nil }
        return CGPoint(x: values[0], y: values[1])
    }
    private func rememberPanelPosition() {
        guard !isPlacingPanel, panel.isVisible else { return }
        UserDefaults.standard.set([Double(panel.frame.minX), Double(panel.frame.maxY)], forKey: Self.panelCornerKey)
    }
    private func positionPanel() {
        guard let screen = Screens.underPointer ?? panel.screen else { return }
        let placed = PanelPlacement.place(size: panelSize, remembered: rememberedPanelCorner,
                                          screens: Screens.visibleFrames, active: screen.visibleFrame)
        model.maxListHeight = max(110, min(460, placed.area.height - 285))
        isPlacingPanel = true
        panel.setFrame(placed.frame, display: true)
        isPlacingPanel = false
    }
    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0, size != panelSize else { return }
        panelSize = size
        guard let panel else { return }
        var frame = PanelPlacement.resize(panel.frame, toHeight: size.height, keepingTopIn: panel.screen?.visibleFrame)
        frame.size.width = size.width
        // Growing keeps the top edge, so this is not a move worth remembering.
        isPlacingPanel = true
        // SwiftUI has already laid out the smaller inbox. AppKit frame animation
        // would resize its host again through intermediate sizes while native
        // text previews and SwiftUI row layers update on different schedules.
        panel.setFrame(frame, display: true)
        isPlacingPanel = false
    }
    private func update(reveal: Bool) {
        let snoozed = model.isSnoozed
        let count = model.items.count
        if let button = statusItem?.button {
            button.title = count == 0 ? "" : " \(count)"
            let deadline = snoozed ? model.inbox.snoozedUntil : nil
            if deadline != indicatedSnoozeDeadline {
                indicatedSnoozeDeadline = deadline
                unsnoozeMenuItem?.isEnabled = snoozed
                if let deadline {
                    let time = deadline.formatted(
                        date: Calendar.current.isDateInToday(deadline) ? .omitted : .abbreviated,
                        time: .shortened
                    )
                    let description = "Snoozed until \(time)"
                    button.image = Self.snoozedStatusImage
                    button.toolTip = description
                    button.setAccessibilityLabel("Splash Finish notifications, \(description)")
                } else {
                    button.image = Self.statusImage
                    button.toolTip = "Splash Finish"
                    button.setAccessibilityLabel("Splash Finish notifications")
                }
            }
        }
        if snoozed || (!reveal && count == 0) { panel.orderOut(nil) }
        else if reveal {
            if !panel.isVisible {
                positionPanel()
                // A newly presented panel takes keyboard focus. Keep it a
                // nonactivating panel so hiding it returns to the previous app.
                panel.makeKeyAndOrderFront(nil)
            } else {
                // A new notification in an already visible panel must not steal
                // focus back from an app the user deliberately switched to.
                panel.orderFrontRegardless()
            }
            NSAccessibility.post(element: panel as Any, notification: .layoutChanged)
        }
    }
    private func handleKey(_ action: PanelKeyAction) -> Bool {
        if action == .open, let event = model.selectedEvent, model.questionID(for: event) != nil { return false }
        switch action {
        case .snooze: model.snooze()
        case .clearAll: model.clear()
        case .previous: model.moveSelection(-1)
        case .next: model.moveSelection(1)
        case .open:
            if let event = model.selectedEvent { model.openSource(event) }
        }
        return true
    }
    @discardableResult
    private func menuItem(_ title: String, _ selector: Selector, _ key: String = "",
                          _ modifiers: NSEvent.ModifierFlags = .command, in menu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        entry.keyEquivalentModifierMask = modifiers
        entry.target = self
        menu.addItem(entry)
        return entry
    }
    private static let statusImage = makeStatusImage(snoozed: false)
    private static let snoozedStatusImage = makeStatusImage(snoozed: true)

    private static func makeStatusImage(snoozed: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            NSColor.labelColor.withAlphaComponent(snoozed ? 0.55 : 1).setFill()
            for (x, y, height) in [(3.0, 3.0, 9.0), (9.0, 4.0, 16.0), (15.0, 11.0, 9.0)] {
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 3.5, height: height), xRadius: 1.75, yRadius: 1.75).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.statusImage
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.toolTip = "Splash Finish"
        statusItem.button?.setAccessibilityLabel("Splash Finish notifications")
        let menu = NSMenu()
        // The same shortcut is registered globally below; the menu item keeps it discoverable.
        menuItem("Show Inbox", #selector(showInbox), "s", [.command, .option], in: menu)
        let snoozeMenu = NSMenu()
        for (title, seconds) in [("15 Minutes", 15.0 * 60), ("1 Hour", 3600.0)] {
            let entry = menuItem(title, #selector(snoozeFor(_:)), in: snoozeMenu)
            entry.representedObject = seconds
        }
        menuItem("Until Tomorrow Morning", #selector(snoozeUntilMorning), in: snoozeMenu)
        let snoozeItem = NSMenuItem(title: "Snooze", action: nil, keyEquivalent: "")
        snoozeItem.submenu = snoozeMenu
        menu.addItem(snoozeItem)
        let unsnoozeItem = menuItem("Unsnooze", #selector(unsnooze), in: menu)
        unsnoozeItem.isEnabled = false
        unsnoozeMenuItem = unsnoozeItem
        menuItem("Clear All Notifications", #selector(clear), "w", in: menu)
        menu.addItem(.separator())
        menuItem("Send Test Notification", #selector(testNotification), "t", in: menu)
        menuItem("Settings…", #selector(showSettings), ",", in: menu)
        menuItem("Integrations…", #selector(showIntegrations), "i", in: menu)
        menu.addItem(.separator())
        if let title = UpdateService.shared.menuTitle {
            menuItem(title, #selector(checkForUpdates), in: menu)
        }
        menuItem("About Splash Finish", #selector(about), in: menu)
        menuItem("Quit Splash Finish", #selector(quit), "q", in: menu)
        statusItem.menu = menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(unsnooze) || model.isSnoozed
    }

    @objc private func unsnooze() { model.unsnooze() }
    @objc private func showInbox() { model.show() }
    @objc private func snoozeFor(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        model.snooze(until: Date().addingTimeInterval(seconds))
    }
    @objc private func snoozeUntilMorning() {
        let now = Date()
        model.snooze(until: now.addingTimeInterval(Snooze.untilTomorrowMorning(now: now)))
    }
    @objc private func clear() { model.clear() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func testNotification() {
        model.receive(AgentEvent(task: UUID().uuidString, agent: "Splash Finish", status: .done,
                                 title: "Your notifications are ready", detail: "Dismiss this one with ×", project: "welcome"))
    }
    @objc private func checkForUpdates() { UpdateService.shared.checkForUpdates() }
    @objc private func about() {
        AppActivation.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Splash Finish",
                                                    .applicationVersion: CLI.version,
                                                    .credits: NSAttributedString(string: "One question. Two results. One window.\ngithub.com/bobuk-io/splash-finish")])
    }
    private func offerIntegrationUpdates() {
        // Hooks embed the absolute binary path, so moving the .app or updating the app
        // leaves stale integrations behind. Offer once per version and location.
        let signature = CLI.version + "|" + CLI.executable
        let key = "integrationUpdateOfferSignature"
        guard UserDefaults.standard.string(forKey: key) != signature,
              let statuses = try? CLI.integrationInstaller().inspect(inbox: model.inbox),
              statuses.contains(where: { $0.state == .updateAvailable }) else { return }
        UserDefaults.standard.set(signature, forKey: key)
        let alert = NSAlert()
        alert.messageText = "Agent integrations can be updated"
        alert.informativeText = "Splash Finish found older integrations. Review them before updating; Codex may require hook trust again."
        alert.addButton(withTitle: "Review Integrations")
        alert.addButton(withTitle: "Later")
        AppActivation.activate()
        if alert.runModal() == .alertFirstButtonReturn { showIntegrations() }
    }
    private func windowRect(forBody size: NSSize) -> NSRect {
        NSRect(origin: .zero, size: ChromeMetrics.windowSize(forBody: size))
    }
    private func resizeSettings(bodyHeight: CGFloat) {
        guard bodyHeight > 100, let window = settingsWindow?.window as? ChromeWindow else { return }
        let target = window.contentSize(forBody: NSSize(width: 480, height: ceil(bodyHeight)))
        let current = window.frame
        let delta = target.height - window.contentRect(forFrameRect: current).height
        guard abs(delta) > 1 else { return }
        let next = NSRect(x: current.origin.x, y: current.origin.y - delta, width: current.width, height: current.height + delta)
        window.setFrame(next, display: true, animate: window.isVisible)
    }
    private func makeWindows() {
        settingsWindow = HostedWindowController(window: { [unowned self] in
            let window = ChromeWindow(contentRect: windowRect(forBody: NSSize(width: 480, height: 590)), theme: .splash,
                                      resizable: false, showsTitle: true)
            window.title = "Settings"
            return window
        }, rootView: { [unowned self] in
            SettingsView(model: model,
                         theme: .splash,
                         installSkills: { [weak self] in self?.changeSkills(install: true) },
                         uninstallSkills: { [weak self] in self?.changeSkills(install: false) },
                         onBodyHeight: { [weak self] height in self?.resizeSettings(bodyHeight: height) })
        })
        integrationsWindow = HostedWindowController(frameName: "Integrations", window: { [unowned self] in
            let window = ChromeWindow(contentRect: windowRect(forBody: NSSize(width: 560, height: 500)), theme: .splash,
                                      showsTitle: true)
            window.title = "Splash Finish — Integrations"
            return window
        }, rootView: { [unowned self] in IntegrationsView(model: model, theme: .splash) })
    }
    @objc private func showSettings() { settingsWindow.show() }
    @objc private func showIntegrations() {
        // Reopening an open window refreshes the integration states, as before.
        (integrationsWindow.window as? ChromeWindow)?.setContent(IntegrationsView(model: model, theme: .splash))
        integrationsWindow.show()
    }
    private func changeSkills(install: Bool) {
        let alert = NSAlert()
        alert.messageText = install ? "Install agent integrations?" : "Remove agent integrations?"
        alert.informativeText = "This updates your Claude Code, Codex and Copilot CLI hooks, the Antigravity plugin, their Splash Finish skills, and the pi extension. Existing unrelated settings are kept. Codex requires hook trust via /hooks."
        alert.addButton(withTitle: install ? "Install" : "Remove")
        alert.addButton(withTitle: "Cancel")
        let piAsk = (try? CLI.integrationInstaller().piAgentAskDetected()) ?? false
        let richQuestions = NSButton(checkboxWithTitle: "Enable rich pi-agent-ask questions", target: nil, action: nil)
        if install {
            if let statuses = try? CLI.integrationInstaller().inspect(inbox: model.inbox),
               let pi = statuses.first(where: { $0.agent == .pi }),
               pi.richQuestionsEnabled || (pi.state == .notInstalled && piAsk) { richQuestions.state = .on }
            richQuestions.toolTip = "Uses pi-agent-ask's public integration events."
            if !piAsk { alert.informativeText += "\n\npi-agent-ask was not detected globally. Install it with: pi install npm:pi-agent-ask. Project-local installations may still work." }
            alert.accessoryView = richQuestions
        }
        AppActivation.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let messages = try CLI.integrationInstaller().run(install: install, agents: AgentKind.allCases,
                                                               richQuestions: install && richQuestions.state == .on)
            let result = NSAlert(); result.messageText = "Splash Finish"; result.informativeText = messages.joined(separator: "\n"); result.runModal()
        } catch { model.report(error); model.show() }
    }
}
