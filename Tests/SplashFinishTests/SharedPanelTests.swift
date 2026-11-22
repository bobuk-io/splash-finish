import AppKit
import BobukCore
import BobukUI
import SplashFinishCore
import SwiftUI
import XCTest
@testable import SplashFinish

final class SharedPanelTests: XCTestCase {
    func testSharedFrameRendersInboxEmptyAndMessageStatesWithoutOpeningWindows() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let suite = "io.bobuk.splash-finish.panel-tests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }

            let model = AppModel(stateURL: root.appendingPathComponent("state.json"))
            model.respectFocus = false
            let theme = ThemeStore(defaults: defaults, keys: ThemeStore.splashKeys,
                                   defaultAppearance: .dark, defaultPreset: .amber,
                                   appliesToApplication: false)

            for dark in [false, true] {
                theme.appearance = dark ? .dark : .light
                for state in ["empty", "inbox", "message"] {
                    model.clear()
                    if state != "empty" {
                        model.receive(AgentEvent(task: "demo-attn", agent: "Claude Code", status: .attention,
                            title: "Ready to review theme PR with [notes](https://example.com)", detail: "Waiting for approval", project: "BobukKit"))
                        model.receive(AgentEvent(task: "demo-done", agent: "Codex", status: .done,
                            title: "Demo build completed", detail: "No personal data or live sessions", project: "Splash Finish"))
                    }
                    model.message = state == "message" ? "Demo status message" : nil
                    let host = NSHostingView(rootView: PanelView(model: model, theme: theme, onOpen: { _ in XCTFail("Unexpected open") }, onSize: { _ in }, onSettings: {}))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 600),
                        styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = theme.chromeAppearance
                    window.contentView = host
                    for _ in 0..<4 {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                        window.setContentSize(host.fittingSize)
                        host.layoutSubtreeIfNeeded()
                    }
                    XCTAssertEqual(host.frame.width, 470, accuracy: 0.5)
                    XCTAssertGreaterThan(host.frame.height, 200)
                    XCTAssertLessThan(host.frame.height, 700)
                    @MainActor func surfaces(_ view: NSView) -> [PickerSurfaceView] {
                        if let surface = view as? PickerSurfaceView { return [surface] }
                        return view.subviews.flatMap { surfaces($0) }
                    }
                    XCTAssertEqual(surfaces(host).count, 1)
                    XCTAssertFalse(window.isVisible)
                    if let directory = ProcessInfo.processInfo.environment["BOBUKKIT_PREVIEW_DIR"] {
                        let output = URL(fileURLWithPath: directory)
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        try png.write(to: output.appendingPathComponent("splash-\(dark ? "dark" : "light")-\(state).png"))
                    }
                    window.close()
                }
            }
        }
    }

    func testThemedWindowsRenderPanelSettingsAndIntegrationsAcrossPresets() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let suite = "io.bobuk.splash-finish.theme-render.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }

            let model = AppModel(stateURL: root.appendingPathComponent("state.json"))
            model.respectFocus = false
            model.receive(AgentEvent(task: "attn", agent: "Claude Code", status: .attention,
                title: "Confirm theme tokens for [Splash Finish](https://example.com)", detail: "18 presets ready", project: "bobuk.io"))
            model.receive(AgentEvent(task: "done", agent: "Codex", status: .done,
                title: "All tests passing", detail: "BobukKit 0.4.0 synced", project: "BobukKit"))

            let previewDir = ProcessInfo.processInfo.environment["BOBUKKIT_PREVIEW_DIR"].map { URL(fileURLWithPath: $0) }
            if let previewDir { try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true) }

            for (presetID, dark) in [("catppuccin", true), ("kanagawa", false), ("flexoki", true), ("everforest", true)] {
                let preset = try XCTUnwrap(ThemePreset.named(presetID))
                let theme = ThemeStore(defaults: defaults, keys: ThemeStore.splashKeys,
                                       defaultAppearance: dark ? .dark : .light, defaultPreset: preset,
                                       appliesToApplication: false)
                theme.applyPreset(preset)
                theme.appearance = dark ? .dark : .light

                // 1. Inbox Panel
                let panelHost = NSHostingView(rootView: PanelView(model: model, theme: theme, onOpen: { _ in }, onSize: { _ in }, onSettings: {}))
                let panelWin = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 600),
                                        styleMask: .borderless, backing: .buffered, defer: false)
                panelWin.isReleasedWhenClosed = false
                panelWin.appearance = theme.chromeAppearance
                panelWin.contentView = panelHost
                for _ in 0..<3 {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                    panelWin.setContentSize(panelHost.fittingSize)
                    panelHost.layoutSubtreeIfNeeded()
                }
                if let previewDir {
                    let bmp = try XCTUnwrap(panelHost.bitmapImageRepForCachingDisplay(in: panelHost.bounds))
                    panelHost.cacheDisplay(in: panelHost.bounds, to: bmp)
                    try XCTUnwrap(bmp.representation(using: .png, properties: [:])).write(
                        to: previewDir.appendingPathComponent("panel-\(presetID)-\(dark ? "dark" : "light").png"))
                }
                panelWin.close()

                // 2. Settings Window
                let settingsWin = ChromeWindow(
                    contentRect: NSRect(origin: .zero, size: ChromeMetrics.windowSize(forBody: NSSize(width: 460, height: 550))),
                    theme: theme, resizable: false, showsTitle: true)
                settingsWin.title = "Settings"
                settingsWin.setContent(SettingsView(model: model, theme: theme, installSkills: {}, uninstallSkills: {}))
                if let content = settingsWin.contentView {
                    content.layoutSubtreeIfNeeded()
                    content.displayIfNeeded()
                    XCTAssertFalse(settingsWin.isVisible)
                    if let previewDir {
                        let bmp = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                        content.cacheDisplay(in: content.bounds, to: bmp)
                        try XCTUnwrap(bmp.representation(using: .png, properties: [:])).write(
                            to: previewDir.appendingPathComponent("settings-\(presetID)-\(dark ? "dark" : "light").png"))
                    }
                }
                settingsWin.close()

                // 3. Integrations Window
                let intWin = ChromeWindow(
                    contentRect: NSRect(origin: .zero, size: ChromeMetrics.windowSize(forBody: NSSize(width: 560, height: 500))),
                    theme: theme, showsTitle: true)
                intWin.title = "Splash Finish — Integrations"
                intWin.setContent(IntegrationsView(model: model, theme: theme))
                if let content = intWin.contentView {
                    for _ in 0..<2 {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                        content.layoutSubtreeIfNeeded()
                        content.displayIfNeeded()
                    }
                    XCTAssertFalse(intWin.isVisible)
                    if let previewDir {
                        let bmp = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                        content.cacheDisplay(in: content.bounds, to: bmp)
                        try XCTUnwrap(bmp.representation(using: .png, properties: [:])).write(
                            to: previewDir.appendingPathComponent("integrations-\(presetID)-\(dark ? "dark" : "light").png"))
                    }
                }
                intWin.close()
            }
        }
    }
}
