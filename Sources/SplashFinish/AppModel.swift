import AppKit
import Observation
import OSLog
import SplashFinishCore

@MainActor @Observable final class AppModel {
    private(set) var inbox = Inbox()
    private(set) var selection = KeyboardSelection()
    private(set) var questions: [String: PiQuestion] = [:]
    private(set) var questionErrors: [String: String] = [:]
    private(set) var submittingQuestions = Set<String>()
    @ObservationIgnored private var questionConnections: [String: QuestionConnection] = [:]
    var message: String?
    var maxListHeight: CGFloat = 420
    @ObservationIgnored var onChange: ((Bool) -> Void)?
    @ObservationIgnored private let state: StateFile
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var persistTimer: Timer?
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
        // Connections are ephemeral; discard stale placeholders after an app restart.
        inbox.discardQuestionPlaceholders()
        selection.reconcile(keys: orderedKeys)
        scheduleWake()
    }
    var items: [AgentEvent] {
        inbox.items.filter { event in
            guard event.agent.lowercased() == "pi", event.status == .attention else { return true }
            return !questions.values.contains { $0.session == event.task }
        }
    }
    var attention: [AgentEvent] { items.filter { $0.status == .attention } }
    var completed: [AgentEvent] { items.filter { $0.status == .done } }
    private var orderedKeys: [String] { (attention + completed).map(\.key) }
    var selectedKey: String? { selection.key }
    var selectedEvent: AgentEvent? { (attention + completed).first { $0.key == selection.key } }
    func moveSelection(_ direction: Int) { selection.move(direction, keys: orderedKeys) }
    var isSnoozed: Bool { inbox.snoozedUntil.map { $0 > Date() } ?? false }

    func receive(_ event: AgentEvent) {
        do {
            let received = try inbox.receive(event)
            selection.reconcile(keys: orderedKeys)
            persist(); scheduleWake(); onChange?(shouldReveal(received))
        } catch { report(error) }
    }
    var respectFocus = UserDefaults.standard.object(forKey: "respectFocus") as? Bool ?? true
    @ObservationIgnored private var focusCache: (checked: Date, active: Bool)?
    /// While Do Not Disturb is on the event still lands in the inbox and updates the
    /// badge, but the panel does not open until the user asks for it.
    private func shouldReveal(_ received: Bool) -> Bool {
        guard received, respectFocus else { return received }
        if let cache = focusCache, Date().timeIntervalSince(cache.checked) < 5 { return !cache.active }
        let active = FocusStatus.isDoNotDisturbActive()
        focusCache = (Date(), active)
        return !active
    }
    func openQuestion(id: String) {
        guard questionConnections[id] == nil, let connection = QuestionConnection(id: id) else { return }
        questionConnections[id] = connection
        connection.onQuestion = { [weak self] question in
            guard let self else { return }
            self.questions[id] = question
            self.receive(AgentEvent(task: "question-" + id, agent: "pi", status: .attention,
                                    title: "Question awaiting your answer", detail: "pi-agent-ask", project: question.project,
                                    source: question.orca.map { EventSource(bundleID: OrcaSource.bundleID, orca: $0) }))
        }
        connection.onResult = { [weak self] ok, error in
            guard let self else { return }
            self.submittingQuestions.remove(id)
            self.questionErrors[id] = ok ? nil : (error ?? "Pi did not accept the answer.")
        }
        connection.onEnd = { [weak self] in
            guard let self else { return }
            let lostConfirmation = self.submittingQuestions.remove(id) != nil
            let failure = self.questionErrors[id]
            if lostConfirmation || failure != nil {
                self.message = failure ?? "Answer confirmation was lost. Check the question in pi."
            }
            self.questions.removeValue(forKey: id)
            self.questionErrors.removeValue(forKey: id)
            self.questionConnections.removeValue(forKey: id)
            self.inbox.dismiss(key: "pi:question-" + id)
            self.selection.reconcile(keys: self.orderedKeys)
            self.persist(); self.scheduleWake(); self.onChange?(lostConfirmation || failure != nil)
        }
        connection.start()
    }
    func answerQuestion(id: String, value: [String: Any]) {
        guard let connection = questionConnections[id], !submittingQuestions.contains(id) else { return }
        questionErrors[id] = nil; submittingQuestions.insert(id)
        if !connection.answer(value) {
            submittingQuestions.remove(id); questionErrors[id] = "Answer is too large or the connection is unavailable."
        }
    }
    func usePi(id: String) {
        let event = inbox.items.first { questionID(for: $0) == id }
        questionConnections[id]?.end()
        if let event, event.source?.orca != nil { SourceNavigator.open(event, model: self) }
    }
    func questionID(for event: AgentEvent) -> String? {
        guard event.agent.lowercased() == "pi", let id = QuestionTask.id(fromTask: event.task) else { return nil }
        return questions[id] == nil ? nil : id
    }
    func dismiss(_ event: AgentEvent) {
        if let id = questionID(for: event) { usePi(id: id); return }
        inbox.dismiss(key: event.key); selection.reconcile(keys: orderedKeys)
        persist(); scheduleWake(); onChange?(false)
    }
    func clear() {
        // Pending questions remain visible: clearing a notification must not strand an agent.
        let keep = Set(inbox.items.compactMap { event in questionID(for: event).map { _ in event.key } })
        inbox.dismissAll(except: keep)
        selection.reconcile(keys: orderedKeys)
        persist(); scheduleWake(); onChange?(false)
    }
    func snooze(duration: TimeInterval = 15 * 60) {
        inbox.snooze(duration: duration); persist(); scheduleWake(); onChange?(false)
    }
    func show() { inbox.reveal(); persist(); scheduleWake(); onChange?(true) }
    func report(_ error: Error) {
        message = error.localizedDescription
        logger.error("\(error.localizedDescription, privacy: .public)")
    }
    /// Coalesce bursts of tool-progress events into a single state write; the file is
    /// small, but a synchronous write on every hook event is wasted I/O.
    private func persist() {
        persistTimer?.invalidate()
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        persistTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    /// Write immediately, e.g. before the app terminates.
    func flush() {
        persistTimer?.invalidate(); persistTimer = nil
        do { try state.save(inbox) } catch { report(error) }
    }
    private func scheduleWake() {
        timer?.invalidate(); timer = nil
        guard let date = inbox.snoozedUntil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(0.05, date.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.inbox.wakeIfDue() { self.persist(); self.onChange?(self.shouldReveal(true)) }
                else { self.scheduleWake() }
            }
        }
    }
}
