// The floating panel of every bobuk-io app (Ting's selecta/launcha/Clipbawd, Splash Finish's inbox,
// HAScS's scenes, lowkey's ⌘L prompt). One place for the NSPanel flags, closing on focus loss with
// a suspension while a menu tracks, Esc and ⌘W, and edit-command routing in non-activating panels.
import AppKit
import BobukCore

@MainActor open class BobukPanel: NSPanel, Sendable {
    public enum Kind: Sendable {
        /// Above everything, on every Space and over full-screen apps, never in the window cycle;
        /// non-activating. Ting's leader menu, launcha, Clipbawd and micro-app flows.
        case launcher
        /// A floating, non-activating panel on every Space. Splash Finish's inbox, HAScS's scenes.
        case floating
        /// A floating prompt that activates the app and moves to the active Space; it closes when
        /// the app is deactivated. lowkey's ⌘L.
        case prompt
        /// A click-through overlay that never takes keys. Ting's toast.
        case hud
    }

    public enum DismissReason: Equatable, Sendable {
        case resignedKey, escape, commandW, appDeactivated, programmatic
    }

    public let kind: Kind
    /// Close when another window takes key status (focus loss). Off for `.hud`.
    public var dismissesOnResignKey: Bool
    public var dismissesOnEscape = true
    public var dismissesOnCommandW = true
    /// On for `.prompt`.
    public var dismissesOnAppDeactivation: Bool
    /// Send ⌘C/⌘V/⌘X/⌘A/⌘Z/⇧⌘Z to the responder chain by the Latin key. On for non-activating
    /// panels, which have no live Edit menu.
    public var routesEditCommands: Bool
    /// Swallow every other ⌘ shortcut (⌘Q must not quit from a panel). Turn it off when the panel's
    /// SwiftUI content has its own `.keyboardShortcut`s (⌘W, ⌘1…⌘9, ⌘↩) that must reach it.
    public var swallowsOtherCommandKeys: Bool
    /// True also lets the panel become main (HAScS's scene grid).
    public var allowsMain = false
    /// What dismissing does; nil orders the panel out. Apps reset their state here.
    public var onDismiss: ((DismissReason) -> Void)?
    /// The app's first look at a ⌘ shortcut; return true when it handled the event.
    public var onCommandKey: ((NSEvent, EditCommand) -> Bool)?
    public private(set) var isDismissalSuspended = false
    private var deactivationObserver: NSObjectProtocol?
    nonisolated(unsafe) private var themeObserver: NSObjectProtocol?

    public init(contentRect: NSRect = NSRect(x: 0, y: 0, width: 480, height: 320), kind: Kind) {
        self.kind = kind
        let nonactivating = kind != .prompt
        var mask: NSWindow.StyleMask = [.borderless]
        if nonactivating { mask.insert(.nonactivatingPanel) }
        dismissesOnResignKey = kind != .hud
        dismissesOnAppDeactivation = kind == .prompt
        routesEditCommands = nonactivating
        swallowsOtherCommandKeys = nonactivating
        super.init(contentRect: contentRect, styleMask: mask, backing: .buffered, defer: true)
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        switch kind {
        case .launcher, .hud:
            level = .popUpMenu
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        case .floating:
            level = .floating
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        case .prompt:
            level = .floating
            collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        }
        if kind == .hud {
            ignoresMouseEvents = true
            hasShadow = false
        }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.dismissesOnAppDeactivation, self.isVisible else { return }
                self.dismiss(.appDeactivated)
            }
        }
    }

    deinit {
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    /// Keeps the panel's effective appearance synchronized with a `ThemeStore` (so native controls
    /// and tooltips inside a custom-colored surface always match its luminance).
    public func bindTheme(_ theme: ThemeStore) {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        appearance = theme.chromeAppearance
        themeObserver = NotificationCenter.default.addObserver(
            forName: ThemeStore.didChangeNotification,
            object: theme,
            queue: .main
        ) { [weak self, weak theme] _ in
            MainActor.assumeIsolated {
                guard let self, let theme else { return }
                self.appearance = theme.chromeAppearance
            }
        }
    }

    open override var canBecomeKey: Bool { kind != .hud }
    open override var canBecomeMain: Bool { allowsMain }

    /// Closes the panel the way the app wants (`onDismiss`), or orders it out.
    public func dismiss(_ reason: DismissReason = .programmatic) {
        if let onDismiss { onDismiss(reason) } else { orderOut(nil) }
    }

    /// While a menu (a context menu, a popover) tracks over the panel, losing key status must
    /// not close it.
    public func suspendDismissal() { isDismissalSuspended = true }

    /// The menu is gone: take keys again, or close when another window took focus meanwhile.
    public func resumeDismissal() {
        isDismissalSuspended = false
        guard isVisible else { return }
        if let key = NSApp.keyWindow, key !== self { dismiss(.resignedKey) } else { makeKeyAndOrderFront(nil) }
    }

    open override func resignKey() {
        super.resignKey()
        guard isVisible, dismissesOnResignKey, !isDismissalSuspended else { return }
        dismiss(.resignedKey)
    }

    open override func cancelOperation(_ sender: Any?) {
        if dismissesOnEscape { dismiss(.escape) } else { super.cancelOperation(sender) }
    }

    open override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let command = EditCommand.classify(event)
        if onCommandKey?(event, command) == true { return true }
        switch command {
        case .notCommand:
            return super.performKeyEquivalent(with: event)
        case .editor:
            // Return false at once so the event reaches the text field's keyDown.
            return false
        case .close where dismissesOnCommandW:
            dismiss(.commandW)
            return true
        case .text(let selector) where routesEditCommands:
            if EditCommand.send(selector, in: self) { return true }
            return swallowsOtherCommandKeys ? true : super.performKeyEquivalent(with: event)
        case .close, .text, .commandReturn, .other:
            if super.performKeyEquivalent(with: event) { return true }
            return swallowsOtherCommandKeys
        }
    }
}
