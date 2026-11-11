import AppKit
import SwiftUI
import Network
import Darwin
import SplashFinishCore

struct PiQuestion: Decodable {
    struct Option: Decodable, Identifiable {
        var id: String { value }
        let value: String
        let label: String
        let description: String?
        let recommended: Bool?
    }
    struct Item: Decodable, Identifiable {
        let id: String
        let label: String
        let prompt: String
        let context: String?
        let type: String
        let options: [Option]
    }
    let title: String?
    let questions: [Item]
    let project: String
    let session: String?
    let orca: OrcaSource?
}

@MainActor final class QuestionConnection: Identifiable {
    let id: String
    private let connection: NWConnection
    private var buffer = Data()
    private var ended = false
    private var receivedForm = false
    var onQuestion: ((PiQuestion) -> Void)?
    var onResult: ((Bool, String?) -> Void)?
    var onEnd: (() -> Void)?

    init?(id: String) {
        guard id.utf8.count == 32, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        let directory = "/tmp/sf-\(getuid())"
        let socket = "\(directory)/\(id).sock"
        var dirInfo = stat(), socketInfo = stat()
        guard lstat(directory, &dirInfo) == 0, dirInfo.st_mode & S_IFMT == S_IFDIR,
              dirInfo.st_uid == getuid(), dirInfo.st_mode & 0o077 == 0,
              lstat(socket, &socketInfo) == 0, socketInfo.st_mode & S_IFMT == S_IFSOCK,
              socketInfo.st_uid == getuid() else { return nil }
        self.id = id
        self.connection = NWConnection(to: .unix(path: socket), using: .tcp)
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: self?.receive()
                case .failed, .cancelled: self?.end()
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, !self.ended else { return }
                if let data { self.buffer.append(data) }
                guard self.buffer.count <= 131072 else { self.end(); return }
                while let newline = self.buffer.firstIndex(of: 10) {
                    let line = Data(self.buffer.prefix(upTo: newline))
                    self.buffer.removeSubrange(...newline)
                    if !self.receivedForm {
                        guard let form = try? JSONDecoder().decode(PiQuestion.self, from: line),
                              !form.questions.isEmpty, form.questions.count <= 20,
                              form.questions.allSatisfy({ !$0.id.isEmpty && !$0.options.isEmpty && $0.options.count <= 30 }) else { self.end(); return }
                        if let orca = form.orca, (try? orca.validated()) == nil { self.end(); return }
                        self.receivedForm = true; self.onQuestion?(form)
                    } else if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let type = object["type"] as? String {
                        if type == "result", let ok = object["ok"] as? Bool { self.onResult?(ok, object["message"] as? String) }
                        else if type == "closed" { self.end(); return }
                    } else { self.end(); return }
                }
                if complete || error != nil { self.end() } else { self.receive() }
            }
        }
    }
    @discardableResult func answer(_ value: [String: Any]) -> Bool {
        guard !ended, let data = try? JSONSerialization.data(withJSONObject: value), data.count <= 131072 else { return false }
        connection.send(content: data + Data([10]), completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated { if error != nil { self?.end() } }
        })
        return true
    }
    func end() {
        guard !ended else { return }; ended = true
        connection.cancel(); onEnd?()
    }
}

private struct AnswerDraft {
    var values = Set<String>()
    var customText = ""
    var note = ""
    var optionNotes = [String: String]()
    var hasAnswer: Bool { !values.isEmpty || !customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private struct PiQuestionItemView: View {
    let question: PiQuestion.Item
    @Binding var draft: AnswerDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(question.label.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
            Text(question.prompt).font(.system(size: 15, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            if let context = question.context, !context.isEmpty {
                Text(context).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                Button {
                    if question.type == "multi" {
                        if draft.values.contains(option.value) { draft.values.remove(option.value) } else { draft.values.insert(option.value) }
                    } else { draft.values = [option.value]; draft.customText = "" }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: draft.values.contains(option.value) ? (question.type == "multi" ? "checkmark.square.fill" : "largecircle.fill.circle") : (question.type == "multi" ? "square" : "circle"))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(option.label); if option.recommended == true { Text("Recommended").font(.caption).foregroundStyle(.secondary) } }
                            if let description = option.description, !description.isEmpty { Text(description).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    // ⌘1…⌘9 select options without stealing plain digits from text fields.
                    .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command) : nil)
                    .help(index < 9 ? "\(option.label) (⌘\(index + 1))" : option.label)
                if draft.values.contains(option.value) {
                    TextField("Option note (optional)", text: Binding(get: { draft.optionNotes[option.value] ?? "" }, set: { draft.optionNotes[option.value] = $0 }))
                        .textFieldStyle(.roundedBorder).padding(.leading, 20)
                }
            }
            TextField("Your own answer (optional)", text: $draft.customText)
                .textFieldStyle(.roundedBorder)
                .onChange(of: draft.customText) { _, value in if question.type == "single" && !value.isEmpty { draft.values.removeAll() } }
            TextField("Question note (optional)", text: $draft.note).textFieldStyle(.roundedBorder)
        }
    }
}

struct PiQuestionView: View {
    let question: PiQuestion
    let submit: ([String: Any]) -> Void
    let usePi: () -> Void
    let submitting: Bool
    let error: String?
    @State private var drafts: [String: AnswerDraft] = [:]
    private var canSubmit: Bool { question.questions.allSatisfy { drafts[$0.id]?.hasAnswer == true } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("PI / \(question.project.uppercased())").font(.system(size: 10, weight: .semibold, design: .monospaced))
                Spacer()
                Text("PI-AGENT-ASK").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
            if let title = question.title, !title.isEmpty { Text(title).font(.headline) }
            ForEach(question.questions) { item in
                PiQuestionItemView(question: item, draft: Binding(get: { drafts[item.id] ?? AnswerDraft() }, set: { drafts[item.id] = $0 }))
                if item.id != question.questions.last?.id { Divider() }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Answer in pi", action: usePi).help("Close this card and continue in the original pi dialog")
                Spacer()
                Button(submitting ? "Submitting…" : "Submit") {
                    var answers = [String: [String: Any]]()
                    for item in question.questions {
                        let draft = drafts[item.id] ?? AnswerDraft()
                        var answer: [String: Any] = ["values": item.options.map(\.value).filter { draft.values.contains($0) }]
                        let text = draft.customText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { answer["customText"] = text }
                        if !note.isEmpty { answer["note"] = note }
                        let notes = draft.optionNotes.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        if !notes.isEmpty { answer["optionNotes"] = notes }
                        answers[item.id] = answer
                    }
                    submit(["kind": "answer", "answers": answers])
                }.disabled(!canSubmit || submitting)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Submit the answers to pi (⌘⏎)")
            }
        }.padding(12).background(Color.panelInk.opacity(0.05), in: .rect(cornerRadius: 8))
    }
}
