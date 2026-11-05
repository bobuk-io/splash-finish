import AppKit
import SwiftUI
import ServiceManagement
import Sparkle
import SplashFinishCore

private final class SplashPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var panel: SplashPanel!
    private var statusItem: NSStatusItem!
    private var appLock: FileLock?
    private var panelSize = CGSize(width: 470, height: 350)
    private var integrationsWindow: NSWindow?
    private var updater: SPUStandardUpdaterController?
    private var pendingURLs = [URL]()
    private var observers = [NSObjectProtocol]()

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
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: PanelView(model: model,
            onOpen: { [weak self] event in
                guard let self else { return }
                SourceNavigator.open(event, model: self.model)
            }, onSize: { [weak self] size in
                DispatchQueue.main.async { self?.resize(to: size) }
            }))
        model.onChange = { [weak self] reveal in self?.update(reveal: reveal) }
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        makeMenu()
        update(reveal: !model.items.isEmpty && !model.isSnoozed)
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
        case "show": model.show()
        case "snooze": model.snooze()
        case "clear": model.clear()
        default: model.report(EventError.invalid("Unknown Splash Finish URL command"))
        }
    }
    private var activeScreen: NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? panel?.screen ?? NSScreen.main
    }
    private func positionPanel() {
        guard let screen = activeScreen else { return }
        let area = screen.visibleFrame
        model.maxListHeight = max(110, min(460, area.height - 285))
        let size = panelSize
        let y = max(area.minY + 16, min(area.maxY - size.height - 16, area.midY - size.height / 2 - 55))
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: y, width: size.width, height: size.height), display: true)
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
        panel.setFrame(frame, display: true, animate: panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    private func update(reveal: Bool) {
        statusItem?.button?.title = model.items.isEmpty ? "" : " \(model.items.count)"
        if model.isSnoozed || (!reveal && model.items.isEmpty) { panel.orderOut(nil) }
        else if reveal {
            if !panel.isVisible { positionPanel() }
            // Do not activate the app or take the keyboard away from the user's work.
            panel.orderFrontRegardless()
            NSAccessibility.post(element: panel as Any, notification: .layoutChanged)
        }
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
        func item(_ title: String, _ selector: Selector, _ key: String = "") {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            entry.target = self; menu.addItem(entry)
        }
        item("Show Inbox", #selector(showInbox), "0")
        item("Snooze for 15 Minutes", #selector(snooze), "s")
        item("Clear All Notifications", #selector(clear), "w")
        menu.addItem(.separator())
        item("Send Test Notification", #selector(testNotification), "t")
        item("Integrations…", #selector(showIntegrations), "i")
        item("Install Agent Skills…", #selector(installSkills))
        item("Uninstall Agent Skills…", #selector(uninstallSkills))
        item("Start at Login", #selector(toggleLogin))
        menu.items.last?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        item("Check for Updates…", #selector(checkForUpdates))
        item("About Splash Finish", #selector(about))
        item("Quit Splash Finish", #selector(quit), "q")
        statusItem.menu = menu
    }
    @objc private func showInbox() { model.show() }
    @objc private func snooze() { model.snooze() }
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
                                                    .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
                                                    .credits: NSAttributedString(string: "One question. Two results. One window.\ngithub.com/bobuk-io/splash-finish")])
    }
    private func offerIntegrationUpdates() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? CLI.version
        let key = "integrationUpdateOfferVersion"
        guard UserDefaults.standard.string(forKey: key) != version,
              let statuses = try? CLI.integrationInstaller().inspect(inbox: model.inbox),
              statuses.contains(where: { $0.state == "update available" }) else { return }
        UserDefaults.standard.set(version, forKey: key)
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
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let messages = try CLI.integrationInstaller().run(install: install, agents: AgentKind.allCases)
            let result = NSAlert(); result.messageText = "Splash Finish"; result.informativeText = messages.joined(separator: "\n"); result.runModal()
        } catch { model.report(error); model.show() }
    }
    @objc private func toggleLogin() {
        LoginItem.toggle(model: model, menu: statusItem.menu)
    }
}
