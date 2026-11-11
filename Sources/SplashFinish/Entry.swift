import AppKit
import ServiceManagement
import SplashFinishCore

@main struct SplashFinishMain {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if !args.isEmpty && !args[0].hasPrefix("-psn_") {
            exit(CLI.run(args))
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor enum LoginItem {
    static func toggle(model: AppModel) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch { model.report(error); model.show() }
    }
}
