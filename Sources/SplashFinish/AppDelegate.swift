import AppKit
import SwiftUI
import ServiceManagement
import Sparkle
import SplashFinishCore

private final class SplashPanel: NSPanel {
    var onKeyAction: ((PanelKeyAction) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown, isKeyWindow else { super.sendEvent(event); return }
        // Text editing must never trigger inbox-wide shortcuts or navigation.
        if firstResponder is NSTextView { super.sendEvent(event); return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // Swallow repeats of destructive or one-shot shortcuts rather than passing
        // them to another responder; arrow-key repeats still navigate normally.
        if modifiers.isEmpty, event.isARepeat, [UInt16(53), 51, 36, 76].contains(event.keyCode) { return }
        if let action = PanelKeyAction.from(keyCode: event.keyCode,
                                            hasCommandModifiers: !modifiers.isEmpty,
                                            isRepeat: event.isARepeat) {
            if onKeyAction?(action) == true { return }
            super.sendEvent(event)
            return
        }
        super.sendEvent(event)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var panel: SplashPanel!
    private var statusItem: NSStatusItem!
    private var appLock: FileLock?
    private var panelSize = CGSize(width: 470, height: 350)
    private var integrationsWindow: NSWindow?
    private var updater: SPUStandardUpdaterController?
    private var hotKey: GlobalHotKey?
    private var startAtLoginItem: NSMenuItem?
    private var pendingURLs = [URL]()
    private var observers = [NSObjectProtocol]()
    /// Programmatic frame changes also post didMove; only user drags are remembered.
    private var isPlacingPanel = false
    private static let panelCornerKey = "panelTopLeft"

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { appLock = try FileLock(url: AppPaths.support.appendingPathComponent("app.lock"), nonblocking: true) }
        catch { NSApp.terminate(nil); return }
        model = AppModel()
        panel = SplashPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Splash Finish"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.onKeyAction = { [weak self] action in self?.handleKey(action) ?? false }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: PanelView(model: model,
            onOpen: { [weak self] event in
                guard let self else { return }
                self.model.openSource(event)
            }, onSize: { [weak self] size in
                DispatchQueue.main.async { self?.resize(to: size) }
            }))
        model.onChange = { [weak self] reveal in self?.update(reveal: reveal) }
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        hotKey = GlobalHotKey { [weak self] in self?.model.show() }
        makeMenu()
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
        model?.show(); return false
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
    private var activeScreen: NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? panel?.screen ?? NSScreen.main
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
        guard let screen = activeScreen else { return }
        let placed = PanelPlacement.place(size: panelSize, remembered: rememberedPanelCorner,
                                          screens: NSScreen.screens.map(\.visibleFrame), active: screen.visibleFrame)
        model.maxListHeight = max(110, min(460, placed.area.height - 285))
        isPlacingPanel = true
        panel.setFrame(placed.frame, display: true)
        isPlacingPanel = false
    }
    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0, size != panelSize else { return }
        panelSize = size
        guard let panel else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        if let area = panel.screen?.visibleFrame {
            frame.origin.y = max(area.minY + 16, min(area.maxY - size.height - 16, frame.origin.y))
        }
        // Growing keeps the top edge, so this is not a move worth remembering.
        isPlacingPanel = true
        panel.setFrame(frame, display: true, animate: panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        isPlacingPanel = false
    }
    private func update(reveal: Bool) {
        statusItem?.button?.title = model.items.isEmpty ? "" : " \(model.items.count)"
        if model.isSnoozed || (!reveal && model.items.isEmpty) { panel.orderOut(nil) }
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
    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
            NSColor.labelColor.setFill()
            for (x, y, height) in [(3.0, 3.0, 9.0), (9.0, 4.0, 16.0), (15.0, 11.0, 9.0)] {
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 3.5, height: height), xRadius: 1.75, yRadius: 1.75).fill()
            }
            return true
        }
        image.isTemplate = true
        statusItem.button?.image = image
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
        menuItem("Clear All Notifications", #selector(clear), "w", in: menu)
        menu.addItem(.separator())
        menuItem("Send Test Notification", #selector(testNotification), "t", in: menu)
        menuItem("Integrations…", #selector(showIntegrations), "i", in: menu)
        menuItem("Install Agent Skills…", #selector(installSkills), in: menu)
        menuItem("Uninstall Agent Skills…", #selector(uninstallSkills), in: menu)
        startAtLoginItem = menuItem("Start at Login", #selector(toggleLogin), in: menu)
        startAtLoginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let focusItem = menuItem("Respect Do Not Disturb", #selector(toggleRespectFocus), in: menu)
        focusItem.state = model.respectFocus ? .on : .off
        menu.addItem(.separator())
        menuItem("Check for Updates…", #selector(checkForUpdates), in: menu)
        menuItem("About Splash Finish", #selector(about), in: menu)
        menuItem("Quit Splash Finish", #selector(quit), "q", in: menu)
        statusItem.menu = menu
    }
    @objc private func showInbox() { model.show() }
    @objc private func snoozeFor(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        model.snooze(duration: seconds)
    }
    @objc private func snoozeUntilMorning() { model.snooze(duration: Snooze.untilTomorrowMorning()) }
    @objc private func clear() { model.clear() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func testNotification() {
        model.receive(AgentEvent(task: UUID().uuidString, agent: "Splash Finish", status: .done,
                                 title: "Your notifications are ready", detail: "Dismiss this one with ×", project: "welcome"))
    }
    @objc private func checkForUpdates() { updater?.checkForUpdates(nil) }
    @objc private func about() {
        NSApp.activate()
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
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { showIntegrations() }
    }
    @objc private func showIntegrations() {
        if integrationsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Splash Finish — Integrations"
            window.isReleasedWhenClosed = false
            window.center()
            integrationsWindow = window
        }
        integrationsWindow?.contentView = NSHostingView(rootView: IntegrationsView(model: model))
        integrationsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
    @objc private func installSkills() { changeSkills(install: true) }
    @objc private func uninstallSkills() { changeSkills(install: false) }
    private func changeSkills(install: Bool) {
        let alert = NSAlert()
        alert.messageText = install ? "Install agent integrations?" : "Remove agent integrations?"
        alert.informativeText = "This updates your Claude Code and Codex hooks, their Splash Finish skills, and the pi extension. Existing unrelated settings are kept. Codex requires hook trust via /hooks."
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
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let messages = try CLI.integrationInstaller().run(install: install, agents: AgentKind.allCases,
                                                               richQuestions: install && richQuestions.state == .on)
            let result = NSAlert(); result.messageText = "Splash Finish"; result.informativeText = messages.joined(separator: "\n"); result.runModal()
        } catch { model.report(error); model.show() }
    }
    @objc private func toggleLogin() {
        LoginItem.toggle(model: model, item: startAtLoginItem)
    }
    @objc private func toggleRespectFocus(_ sender: NSMenuItem) {
        model.respectFocus.toggle()
        UserDefaults.standard.set(model.respectFocus, forKey: "respectFocus")
        sender.state = model.respectFocus ? .on : .off
    }
}
