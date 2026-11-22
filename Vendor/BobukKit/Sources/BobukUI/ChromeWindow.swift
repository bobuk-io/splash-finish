// The bobuk-io window shell, from lowkey: an accent line, a thin control strip with the close
// button on the left and app buttons on the right, a separator, then the app's content in `body`.
// A titled window with the system title bar hidden, so native rounded corners, shadow, resizing,
// full screen, `performClose`, ⌘W and `windowShouldClose` keep working.
//
// Every app window (Settings, Welcome, update progress, browser windows) uses this class. Close
// and other window controls are `StripButton`s in `strip`, never buttons inside the content.
import AppKit
import SwiftUI

/// The accent line at the top of every window. With `progress` it shows a loading bar.
@MainActor public final class AccentBar: NSView {
    public var color: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    /// 0...1 while something loads; nil draws the solid line.
    public var progress: Double? { didSet { needsDisplay = true } }

    public override func draw(_ dirtyRect: NSRect) {
        guard let progress else {
            color.setFill()
            bounds.fill()
            return
        }
        color.withAlphaComponent(0.3).setFill()
        bounds.fill()
        color.setFill()
        NSRect(x: 0, y: 0, width: bounds.width * max(0.05, min(1, progress)), height: bounds.height).fill()
    }
}

/// The control strip: leading buttons (close first), an optional title, trailing buttons.
/// Dragging the strip moves the window; a double-click does what System Settings says
/// (zoom by default, minimize, or nothing).
@MainActor public final class ChromeStrip: NSView {
    public let closeButton: StripButton
    public private(set) var leading: [StripButton]
    public private(set) var trailing: [StripButton]
    private let leadingStack = NSStackView()
    private let trailingStack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    /// Shown centered in the strip when set and `showsTitle` is true.
    public var title: String = "" { didSet { titleLabel.stringValue = title } }
    public var showsTitle = false { didSet { titleLabel.isHidden = !showsTitle } }
    /// Whether a double-click zooms or minimizes; off for fixed-size windows.
    public var handlesDoubleClick = true

    public init(closeButton: StripButton, leading: [StripButton] = [], trailing: [StripButton] = []) {
        self.closeButton = closeButton
        self.leading = leading
        self.trailing = trailing
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for stack in [leadingStack, trailingStack] {
            stack.orientation = .horizontal
            stack.spacing = ChromeMetrics.buttonSpacing
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
        }
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.isHidden = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setAccessibilityElement(false) // The window title is already announced.
        addSubview(titleLabel)
        for button in [closeButton] + leading { add(button, to: leadingStack) }
        for button in trailing { add(button, to: trailingStack) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ChromeMetrics.stripHeight),
            leadingStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ChromeMetrics.stripInset),
            leadingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ChromeMetrics.stripInset),
            trailingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingStack.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingStack.leadingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func add(_ button: StripButton, to stack: NSStackView) {
        stack.addArrangedSubview(button)
        button.widthAnchor.constraint(equalToConstant: ChromeMetrics.buttonWidth).isActive = true
        button.heightAnchor.constraint(equalToConstant: ChromeMetrics.stripHeight).isActive = true
    }

    /// Adds a button after the existing trailing buttons.
    public func addTrailing(_ button: StripButton) {
        trailing.append(button)
        add(button, to: trailingStack)
    }

    /// Adds a button after the close button and the existing leading buttons.
    public func addLeading(_ button: StripButton) {
        leading.append(button)
        add(button, to: leadingStack)
    }

    public var buttons: [StripButton] { [closeButton] + leading + trailing }

    func applyStyle(_ style: ChromeStyle) {
        appearance = style.appearance
        titleLabel.textColor = style.muted
        for button in buttons { button.needsDisplay = true }
    }

    public override var isFlipped: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { true }

    public override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, handlesDoubleClick else {
            window?.performDrag(with: event)
            return
        }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window?.miniaturize(nil)
        case "None": break
        default: window?.zoom(nil)
        }
    }
}

@MainActor open class ChromeWindow: NSWindow, Sendable {
    public let accentBar = AccentBar()
    public let strip: ChromeStrip
    /// Place the window's content here (or use `setContent`).
    public let body = NSView()
    public let separator = NSView()
    public var closeButton: StripButton { strip.closeButton }
    public private(set) var chromeStyle: ChromeStyle
    /// ⌘W closes through `performClose`, also in apps without a File menu.
    public var closesOnCommandW = true
    /// Esc closes through `performClose`; off by default for windows (on for dialogs).
    public var closesOnEscape = false
    /// Sends ⌘C/⌘V/⌘X/⌘A/⌘Z/⇧⌘Z by the Latin key while a text field or text view has focus, so
    /// fields work in accessory apps without an Edit menu and with Cyrillic layouts. Other first
    /// responders (a WKWebView, whose pages handle these keys themselves) and other ⌘ keys (⌘Q)
    /// are left to the normal key-equivalent path and the app's menu.
    public var routesEditCommands = true
    /// A targeted hide must not let AppKit promote a window that belongs behind another app.
    public var allowsFocus = true
    /// Layer colors are fixed CGColors: repaint when light/dark changes.
    private var appearanceObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var themeObserver: NSObjectProtocol?

    /// Duration of an animated chrome color change (lowkey's Tint mode).
    public static let styleAnimation: CFTimeInterval = 0.2

    /// - Parameters:
    ///   - leading: buttons after the close button.
    ///   - trailing: buttons on the right, such as back, start and forward.
    ///   - resizable: false for fixed windows (Settings forms); also disables zoom and full screen.
    ///   - showsTitle: the window title, muted and centered in the strip.
    public init(contentRect: NSRect, style: ChromeStyle = .system, leading: [StripButton] = [],
                trailing: [StripButton] = [], resizable: Bool = true, showsTitle: Bool = false,
                accentHeight: CGFloat = ChromeMetrics.accentHeight) {
        let close = StripButton(glyph: .close, label: "Close · ⌘W")
        strip = ChromeStrip(closeButton: close, leading: leading, trailing: trailing)
        chromeStyle = style
        var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { mask.insert(.resizable) }
        super.init(contentRect: contentRect, styleMask: mask, backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = false
        tabbingMode = .disallowed
        isReleasedWhenClosed = false
        if resizable { collectionBehavior.insert(.fullScreenPrimary) }
        strip.handlesDoubleClick = resizable
        strip.showsTitle = showsTitle
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(kind)?.isHidden = true
        }
        close.onPress = { [weak self] _ in self?.performClose(nil) }

        let root = NSView()
        root.wantsLayer = true
        strip.wantsLayer = true
        separator.wantsLayer = true
        for view in [accentBar, separator, body] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        for view in [body, accentBar, strip, separator] as [NSView] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            accentBar.topAnchor.constraint(equalTo: root.topAnchor),
            accentBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            accentBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            accentBar.heightAnchor.constraint(equalToConstant: accentHeight),
            strip.topAnchor.constraint(equalTo: accentBar.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: strip.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: ChromeMetrics.separatorHeight),
            body.topAnchor.constraint(equalTo: separator.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        contentView = root
        hideTitlebarContainer()
        applyStyle(animated: false)
        appearanceObservation = observe(\.effectiveAppearance) { window, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { window.applyStyle(animated: false) } }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(fullScreenChanged),
                                               name: NSWindow.didExitFullScreenNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(fullScreenChanged),
                                               name: NSWindow.didEnterFullScreenNotification, object: self)
    }

    public convenience init(contentRect: NSRect, theme: ThemeStore, leading: [StripButton] = [],
                            trailing: [StripButton] = [], resizable: Bool = true, showsTitle: Bool = false,
                            accentHeight: CGFloat = ChromeMetrics.accentHeight) {
        self.init(contentRect: contentRect, style: theme.chromeStyle, leading: leading, trailing: trailing,
                  resizable: resizable, showsTitle: showsTitle, accentHeight: accentHeight)
        bindTheme(theme)
    }

    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    /// Keeps the window's chrome style and control appearance synchronized with a `ThemeStore`.
    public func bindTheme(_ theme: ThemeStore, animated: Bool = false) {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        let sync: @MainActor (Bool) -> Void = { [weak self, weak theme] shouldAnimate in
            guard let self, let theme else { return }
            self.appearance = theme.chromeAppearance
            self.setChromeStyle(theme.chromeStyle, animated: shouldAnimate)
        }
        sync(false)
        themeObserver = NotificationCenter.default.addObserver(
            forName: ThemeStore.didChangeNotification,
            object: theme,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { sync(animated) }
        }
    }

    open override var canBecomeKey: Bool { allowsFocus }
    open override var canBecomeMain: Bool { allowsFocus }

    open override var title: String {
        didSet { strip.title = title }
    }

    /// Layer colors are resolved for one appearance: repaint at once when it changes.
    open override var appearance: NSAppearance? {
        didSet { applyStyle(animated: false) }
    }

    /// Recolors the chrome. `animated` fades the strip, separator and background (lowkey's Tint).
    public func setChromeStyle(_ style: ChromeStyle, animated: Bool = false) {
        let changed = style != chromeStyle
        chromeStyle = style
        if changed || !animated { applyStyle(animated: animated) }
    }

    /// Subclasses repaint their own chrome-colored views here (lowkey's popup origin bar).
    open func chromeStyleDidChange(animated: Bool) {}

    private func applyStyle(animated: Bool) {
        let style = chromeStyle
        backgroundColor = style.panel
        accentBar.color = style.accent
        strip.applyStyle(style)
        paint(strip, style.panel, animated: animated)
        paint(separator, style.separator, animated: animated)
        // The root layer covers the window background; it carries the same color so it can animate.
        if let root = contentView { paint(root, style.panel, animated: animated) }
        accentBar.needsDisplay = true
        chromeStyleDidChange(animated: animated)
    }

    private func paint(_ view: NSView, _ color: NSColor, animated: Bool) {
        guard let layer = view.layer else { return }
        // Resolve dynamic colors for this window's appearance.
        var target = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { target = color.cgColor }
        // An unchanged color keeps a running animation.
        if let old = layer.backgroundColor, old == target { return }
        let current = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        layer.removeAnimation(forKey: "chromeColor")
        if animated, let current {
            let animation = CABasicAnimation(keyPath: "backgroundColor")
            animation.fromValue = current
            animation.toValue = target
            animation.duration = Self.styleAnimation
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(animation, forKey: "chromeColor")
        }
        layer.backgroundColor = target
    }

    /// The transparent title bar still catches clicks; hide it so the strip and the content get them.
    private func hideTitlebarContainer() {
        guard let frameView = contentView?.superview else { return }
        for view in frameView.subviews where String(describing: type(of: view)).contains("NSTitlebarContainerView") {
            view.isHidden = true
        }
    }

    @objc private func fullScreenChanged() { hideTitlebarContainer() }

    /// Asks `windowShouldClose` and closes. AppKit's version clicks the hidden title-bar button,
    /// which spins a nested run loop for the highlight and beeps when the delegate refuses.
    open override func performClose(_ sender: Any?) {
        if let delegate, delegate.windowShouldClose?(self) == false { return }
        close()
    }

    open override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        switch EditCommand.classify(event) {
        case .close where closesOnCommandW:
            performClose(nil)
            return true
        case .text(let selector) where routesEditCommands && firstResponder is NSTextView:
            if EditCommand.send(selector, in: self) { return true }
            return super.performKeyEquivalent(with: event)
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    open override func cancelOperation(_ sender: Any?) {
        if closesOnEscape { performClose(nil) } else { super.cancelOperation(sender) }
    }

    /// Pins `view` to all edges of `body`, replacing what was there.
    public func setContent(_ view: NSView) {
        body.subviews.forEach { $0.removeFromSuperview() }
        view.pinEdges(to: body)
    }

    /// Hosts a SwiftUI view in `body`.
    @discardableResult
    public func setContent<Content: View>(_ rootView: Content) -> NSHostingView<Content> {
        let hosting = ChromeWindow.hosting(rootView)
        setContent(hosting)
        return hosting
    }

    /// An `NSHostingView` for `body`. The hidden title bar is taller than the chrome, so a hosting
    /// view with default safe areas would push its content down by the difference (9 points):
    /// always host SwiftUI in a chrome window through this.
    public static func hosting<Content: View>(_ rootView: Content) -> NSHostingView<Content> {
        let hosting = NSHostingView(rootView: rootView)
        hosting.safeAreaRegions = []
        return hosting
    }

    /// The content size that gives `body` exactly `size`, for `setContentSize` or `contentMinSize`.
    public func contentSize(forBody size: NSSize) -> NSSize {
        NSSize(width: size.width, height: size.height + (contentView?.frame.height ?? 0) - body.frame.height)
    }

    /// Removes the content (stops recorders and timers in it); the chrome stays.
    public func removeContent() { body.subviews.forEach { $0.removeFromSuperview() } }
}
