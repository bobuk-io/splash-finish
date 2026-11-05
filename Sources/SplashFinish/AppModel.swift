import AppKit
import Observation
import OSLog
import SplashFinishCore

@MainActor @Observable final class AppModel {
    private(set) var inbox = Inbox()
    var message: String?
    var maxListHeight: CGFloat = 420
    @ObservationIgnored var onChange: ((Bool) -> Void)?
    @ObservationIgnored private let state: StateFile
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let logger = Logger(subsystem: AppPaths.bundleID, category: "inbox")

    init() {
        state = StateFile(url: AppPaths.state)
        do { inbox = try state.load() }
        catch {
            message = "Could not restore the inbox. See Console for details."
            logger.error("State load failed: \(error.localizedDescription, privacy: .public)")
            // Preserve corrupt state instead of silently overwriting the only copy.
            if FileManager.default.fileExists(atPath: AppPaths.state.path) {
                try? SafeFiles.write(Data(contentsOf: AppPaths.state),
                                     to: AppPaths.state.appendingPathExtension("unreadable-\(UUID().uuidString)"))
            }
        }
        scheduleWake()
    }
    var items: [AgentEvent] { inbox.items }
    var attention: [AgentEvent] { inbox.attention }
    var completed: [AgentEvent] { inbox.completed }
    var isSnoozed: Bool { inbox.snoozedUntil.map { $0 > Date() } ?? false }

    func receive(_ event: AgentEvent) {
        do {
            let reveal = try inbox.receive(event)
            persist(); scheduleWake(); onChange?(reveal)
        } catch { report(error) }
    }
    func dismiss(_ event: AgentEvent) { inbox.dismiss(key: event.key); persist(); scheduleWake(); onChange?(false) }
    func clear() { inbox.clear(); persist(); scheduleWake(); onChange?(false) }
    func snooze() { inbox.snooze(); persist(); scheduleWake(); onChange?(false) }
    func show() { inbox.reveal(); persist(); scheduleWake(); onChange?(true) }
    func report(_ error: Error) {
        message = error.localizedDescription
        logger.error("\(error.localizedDescription, privacy: .public)")
    }
    private func persist() {
        do { try state.save(inbox) } catch { report(error) }
    }
    private func scheduleWake() {
        timer?.invalidate(); timer = nil
        guard let date = inbox.snoozedUntil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(0.05, date.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.inbox.wakeIfDue() { self.persist(); self.onChange?(true) }
                else { self.scheduleWake() }
            }
        }
    }
}
