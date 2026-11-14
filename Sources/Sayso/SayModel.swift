import AppKit
import SwiftUI

/// One voice's streamed answer. The model writes the English, a line "---", then 1–2 phrases to highlight.
struct VoiceOutput: Codable, Equatable {
    var raw = ""
    var streaming = false
    var error: String?

    /// The English text, without the highlight list (or a half-written "---" line while streaming).
    var body: String {
        if let range = raw.range(of: "\n---") { return String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) }
        var text = raw
        if let lastBreak = text.lastIndex(of: "\n"), text[text.index(after: lastBreak)...].allSatisfy({ $0 == "-" }) {
            text = String(text[..<lastBreak])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Phrases to highlight, only those that really occur in the text.
    var highlights: [String] {
        guard let range = raw.range(of: "\n---") else { return [] }
        let text = String(Self.fold(body))
        var lines = raw[range.upperBound...].split(separator: "\n", omittingEmptySubsequences: false)
        // While the list is still arriving its last line is half a phrase; wait for the whole of it.
        if streaming, !lines.isEmpty { lines.removeLast() }
        return lines
            .map { $0.split(separator: "—").first.map(String.init) ?? "" }
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(.init(charactersIn: "\"“”-•"))) }
            .filter { !$0.isEmpty && text.contains(String(Self.fold($0))) }
    }
}

struct GrammarIssue: Codable, Equatable, Hashable {
    let wrong: String
    let fix: String
    let why: String
}

@MainActor
final class SayModel: NSObject, ObservableObject, NSTextViewDelegate {
    @Published var mode: Mode = .polish
    @Published var input = ""
    /// Reply mode only: what the user wants to say back (Chinese or English, optional).
    @Published var note = "" {
        didSet { if note != oldValue { scheduleSave() } }
    }
    /// Bumped to move keyboard focus to the reply-note field.
    @Published var focusNoteRequest = 0
    /// The reply note should take the keyboard as soon as its field is on screen.
    var noteFocusPending = false
    @Published var outputs: [Voice: VoiceOutput] = [:]
    @Published private(set) var issues: [GrammarIssue] = []
    @Published var grammarRaw = ""
    @Published var grammarStreaming = false
    @Published var notice: String?
    /// The notice is about the API key, so it offers a way to Settings.
    @Published var noticeOpensSettings = false
    /// The text the current results belong to; grammar marks show only while the input still matches it.
    @Published private(set) var resultsFor = ""
    /// The reply note the current results were made with.
    @Published private(set) var resultsNote = ""
    /// While a new run streams in, each column keeps showing its previous answer (faded) until new text arrives,
    /// so nothing collapses and re-grows.
    @Published private(set) var ghosts: [Voice: String] = [:]
    @Published var inputHeight: CGFloat = 26
    /// Pinned: stays open when the user clicks elsewhere or switches apps.
    @Published var pinned = false
    /// Where the text came from, when it was selected in an editable field: results can be put back there.
    /// `element` is the field itself when the app lets Sayso write into it directly; otherwise the result is pasted.
    private struct ReplaceTarget {
        let pid: pid_t
        let element: AXUIElement?
        let original: String
    }
    private var replaceTarget: ReplaceTarget?
    var canReplace: Bool { replaceTarget != nil && input == replaceTarget?.original }
    private var recordedRun = true

    /// Set when the user picks a mode by hand, so automatic mode choice doesn't override them.
    private var modeChosenByUser = false
    /// Finished answers per mode, so switching back to a mode shows what it already said about the same text
    /// instead of asking again.
    private struct Answer {
        let outputs: [Voice: VoiceOutput]
        let issues: [GrammarIssue]
        let grammarRaw: String
        let input: String
        let note: String
    }
    private var answers: [Mode: Answer] = [:]
    private var tasks: [Task<Void, Never>] = []
    /// Bumped by every run and cancel, so a stream that was cancelled can't write into the next run's results.
    private var generation = 0
    /// A stream failed because of the API key (missing, rejected, not allowed).
    private var keyProblem = false
    /// When the current run started and when each stream showed its first text and finished (for the event log).
    private var runStarted = Date()
    private var timings: [String: (first: TimeInterval?, done: TimeInterval?)] = [:]

    private func mark(_ stream: String, first: Bool) {
        let elapsed = Date().timeIntervalSince(runStarted)
        var entry = timings[stream] ?? (nil, nil)
        if first { if entry.first == nil { entry.first = elapsed } } else { entry.done = elapsed }
        timings[stream] = entry
    }
    weak var textView: NSTextView?
    var onLayoutChange: ((_ allowShrink: Bool) -> Void)?

    var hasResults: Bool { !outputs.isEmpty }
    var isRunning: Bool { outputs.values.contains { $0.streaming } || grammarStreaming }
    var marksAreCurrent: Bool { input == resultsFor && mode == .polish }
    /// The text or the note was edited after these results were made.
    var isStale: Bool {
        hasResults && !isRunning
            && (input != resultsFor || (mode == .reply && note.trimmingCharacters(in: .whitespacesAndNewlines) != resultsNote))
    }

    /// The answers are out of date and there is something to answer instead (an empty box has nothing to update to).
    var canUpdate: Bool { isStale && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    override init() {
        super.init()
        restore()
    }

    // MARK: Loading text

    /// New text from the shortcut. `editable` says whether it was selected in a text field (the user's own draft)
    /// rather than in read-only content (usually someone else's message).
    func load(text: String, editable: Bool?, element: AXUIElement? = nil, pid: pid_t = 0) {
        cancel()
        answers = [:]
        replaceTarget = editable == true && pid != 0 ? ReplaceTarget(pid: pid, element: element, original: text) : nil
        input = text
        note = ""
        outputs = [:]
        issues = []
        grammarRaw = ""
        resultsFor = ""
        resultsNote = ""
        notice = nil
        noticeOpensSettings = false
        modeChosenByUser = false
        if Self.containsChinese(text) {
            mode = .zh
        } else if let editable {
            mode = editable ? .polish : .reply
        }
        syncTextView()
    }

    /// Puts a result where the original selection is: written straight into the field when the app allows it,
    /// otherwise pasted (the clipboard is restored afterwards). `willPaste` runs just before a paste, when the
    /// panel has to be out of the way; `done` says whether it worked (the caller copies instead if not).
    func replaceOriginal(with text: String, willPaste: @escaping () -> Void, done: @escaping (Bool) -> Void) {
        guard let target = replaceTarget, canReplace else { done(false); return }
        if let element = target.element, Selection.replace(in: element, original: target.original, with: text) {
            replaceTarget = nil
            done(true)
            return
        }
        let testing = ProcessInfo.processInfo.environment["SAYSO_TEST_PASTEBOARD"] != nil
        guard testing || NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { done(false); return }
        let original = target.original.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleID = NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier
        willPaste()
        // Give the app a moment to take the keyboard back from the panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            ClipboardBridge.paste(text, pid: target.pid, stillSelected: { answer in
                if let element = target.element {
                    answer(Selection.selectedText(of: element) == original)
                } else {
                    ClipboardBridge.selectionMatches(original, pid: target.pid, bundleID: bundleID, done: answer)
                }
            }, changed: target.element.map { element in { Selection.selectedText(of: element) != original } }) { pasted in
                DebugLog.write("replace by pasting: \(ClipboardBridge.lastReport)")
                if pasted { self?.replaceTarget = nil }
                done(pasted)
            }
        }
    }

    func clear() {
        load(text: "", editable: nil)
        save()
        onLayoutChange?(true)
    }

    func pick(_ newMode: Mode) {
        guard newMode != mode else { return }
        keepAnswer()
        mode = newMode
        modeChosenByUser = true
        scheduleSave()
        if let answer = answers[newMode], answer.input == input,
           newMode != .reply || answer.note == note.trimmingCharacters(in: .whitespacesAndNewlines) {
            cancel()
            outputs = answer.outputs
            issues = answer.issues
            grammarRaw = answer.grammarRaw
            resultsFor = answer.input
            resultsNote = answer.note
            notice = nil
            noticeOpensSettings = false
            save()
            onLayoutChange?(true)
        } else if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, hasResults || isRunning {
            run()
        }
        // The note field comes and goes with the mode; don't leave the keyboard pointing at nothing.
        DispatchQueue.main.async { [weak self] in self?.focusInput() }
    }

    /// Remembers the current mode's answer if it is complete and still matches the text.
    private func keepAnswer() {
        guard hasResults, !isRunning, input == resultsFor,
              outputs.values.allSatisfy({ $0.error == nil && !$0.raw.isEmpty }) else { return }
        answers[mode] = Answer(outputs: outputs, issues: issues, grammarRaw: grammarRaw, input: resultsFor, note: resultsNote)
    }

    static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    // MARK: Running

    /// A selection this long is more likely a whole document than a message, so it waits for ↩.
    static let autoRunLimit = 4000

    /// Starts on text that came from the shortcut, unless it is unusually long.
    func runSelection() {
        guard input.count > Self.autoRunLimit else { run(); return }
        notice = "That's a long selection (\(input.count.formatted(.number.locale(Locale(identifier: "en_US")))) characters). Press ↩ to send it."
        noticeOpensSettings = false
        onLayoutChange?(true)
    }

    func run() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !modeChosenByUser, mode != .zh, Self.containsChinese(text), !(mode == .reply && Self.hasEnglishLine(text)) {
            mode = .zh
        }
        let note = self.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = outputs.compactMapValues { $0.body.isEmpty ? nil : $0.body }
        cancel()
        notice = nil
        noticeOpensSettings = false
        keyProblem = false
        issues = []
        grammarRaw = ""
        resultsFor = input
        resultsNote = note
        if SecretGuard.containsSecret(text) {
            outputs = [:]
            notice = "This looks like it contains a key or token, so it wasn't sent."
            onLayoutChange?(true)
            return
        }
        let model = AppSettings.shared.model
        let mode = mode
        let gen = generation
        outputs = [.sharp: VoiceOutput(streaming: true), .chill: VoiceOutput(streaming: true)]
        runStarted = Date()
        timings = [:]
        ghosts = previous
        recordedRun = false
        for voice in Voice.allCases {
            tasks.append(Task { [weak self] in
                do {
                    try await OpenAIClient.stream(model: model, instructions: Prompts.instructions(mode: mode, voice: voice),
                                                  input: Prompts.input(mode: mode, voice: voice, text: text, note: note)) { delta in
                        await MainActor.run {
                            guard let self, self.generation == gen else { return }
                            self.mark(voice.rawValue, first: true)
                            self.ghosts[voice] = nil
                            self.outputs[voice]?.raw += delta
                        }
                    }
                } catch is CancellationError {
                } catch let error as URLError where error.code == .cancelled {
                } catch {
                    let message = (error as? APIError)?.errorDescription ?? APIError.describe(error)
                    let settings = (error as? APIError)?.needsSettings ?? false
                    await MainActor.run {
                        guard self?.generation == gen else { return }
                        self?.outputs[voice]?.error = message
                        if settings { self?.keyProblem = true }
                    }
                }
                await MainActor.run {
                    guard let self, self.generation == gen else { return }
                    self.mark(voice.rawValue, first: false)
                    self.finish(voice)
                }
            })
        }
        if mode == .polish {
            grammarStreaming = true
            tasks.append(Task { [weak self] in
                do {
                    try await OpenAIClient.stream(model: model, instructions: Prompts.grammar, input: text, emptyIsAnAnswer: true) { delta in
                        await MainActor.run {
                            guard let self, self.generation == gen else { return }
                            self.mark("grammar", first: true)
                            self.appendGrammar(delta)
                        }
                    }
                } catch {}
                await MainActor.run {
                    guard self?.generation == gen else { return }
                    self?.mark("grammar", first: false)
                    self?.grammarStreaming = false
                    self?.parseGrammar(final: true)
                    self?.settle()
                }
            })
        }
        onLayoutChange?(false)
    }

    private static func hasEnglishLine(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in !containsChinese(String(line)) && line.contains { $0.isLetter } }
    }

    private func finish(_ voice: Voice) {
        guard outputs[voice]?.streaming == true else { return }
        outputs[voice]?.streaming = false
        ghosts[voice] = nil
        if outputs[voice]?.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true, outputs[voice]?.error == nil {
            outputs[voice]?.error = "Nothing came back. Press ↩ to try again."
        }
        settle()
    }

    /// Once every stream of a run has ended (the two voices and, in Polish, the grammar check).
    private func settle() {
        guard !isRunning else { return }
        // How long each stream took to show its first text and to finish (seconds; never the text).
        let report = ["sharp", "chill", "grammar"].compactMap { name -> String? in
            guard let timing = timings[name] else { return nil }
            let first = timing.first.map { String(format: "%.2f", $0) } ?? "-"
            return "\(name) first=\(first) done=\(String(format: "%.2f", timing.done ?? 0))"
        }.joined(separator: ", ")
        if !report.isEmpty { DebugLog.write("run: mode=\(mode.rawValue) model=\(AppSettings.shared.model.name) chars=\(resultsFor.count) \(report)") }
        timings = [:]
        // The same failure in both columns reads better once, across the panel.
        if let first = outputs[.sharp]?.error, outputs[.sharp]?.body.isEmpty == true,
           outputs[.chill]?.error == first, outputs[.chill]?.body.isEmpty == true {
            outputs = [:]
            notice = first
            noticeOpensSettings = keyProblem
        }
        save()
        recordHistory()
        onLayoutChange?(true)
    }

    /// Once every stream of a run is done, keep it in the history (if anything came back).
    private func recordHistory() {
        guard !recordedRun, !isRunning else { return }
        // Only finished answers are worth keeping.
        func kept(_ voice: Voice) -> String { outputs[voice].map { $0.error == nil ? $0.raw : "" } ?? "" }
        let sharp = kept(.sharp), chill = kept(.chill)
        guard !(sharp.isEmpty && chill.isEmpty) else { return }
        recordedRun = true
        HistoryStore.shared.record(HistoryEntry(mode: mode, input: resultsFor.trimmingCharacters(in: .whitespacesAndNewlines), note: resultsNote,
                                                sharp: sharp, chill: chill, grammar: grammarRaw))
    }

    /// Shows a past result as it was, without asking again.
    func load(entry: HistoryEntry) {
        cancel()
        replaceTarget = nil
        mode = entry.mode
        modeChosenByUser = true
        input = entry.input
        note = entry.note
        resultsFor = entry.input
        resultsNote = entry.note
        outputs = [.sharp: VoiceOutput(raw: entry.sharp), .chill: VoiceOutput(raw: entry.chill)]
        grammarRaw = entry.grammar
        notice = nil
        noticeOpensSettings = false
        issues = []
        syncTextView()
        parseGrammar(final: true)
        save()
        onLayoutChange?(true)
    }

    func cancel() {
        generation += 1
        ghosts = [:]
        tasks.forEach { $0.cancel() }
        tasks = []
        for voice in Voice.allCases where outputs[voice]?.streaming == true { outputs[voice]?.streaming = false }
        grammarStreaming = false
    }

    private func appendGrammar(_ delta: String) {
        grammarRaw += delta
        parseGrammar(final: false)
    }

    /// Each finished line is one JSON issue; keep only those whose "wrong" text is really in the input.
    private func parseGrammar(final: Bool) {
        var lines = grammarRaw.components(separatedBy: "\n")
        if !final { lines.removeLast() }
        let parsed = lines.compactMap { line -> GrammarIssue? in
            guard let data = line.trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let issue = try? JSONDecoder().decode(GrammarIssue.self, from: data),
                  !issue.wrong.isEmpty, issue.wrong != issue.fix, resultsFor.contains(issue.wrong) else { return nil }
            return issue
        }
        if parsed != issues {
            issues = parsed
            applyMarks()
        }
    }

    // MARK: Input text view

    func register(_ textView: NSTextView) {
        self.textView = textView
        syncTextView()
    }

    private func syncTextView() {
        guard let textView, textView.string != input else { applyMarks(); return }
        textView.string = input
        textView.setSelectedRange(NSRange(location: (input as NSString).length, length: 0))
        applyMarks()
        measureInput()
    }

    /// Puts the cursor where the user is most likely to type next: the reply note once there's a message to
    /// answer, otherwise the main text.
    func focusInput() {
        if mode == .reply, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            noteFocusPending = true
            focusNoteRequest += 1
            return
        }
        focusText()
    }

    /// Puts the cursor in the main text.
    func focusText() {
        noteFocusPending = false
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    /// Red dotted underline (the system's spelling mark) under each mistake, with its reason as a tooltip.
    func applyMarks() {
        guard let textView, let storage = textView.textStorage, let layout = textView.layoutManager else { return }
        let whole = NSRange(location: 0, length: storage.length)
        layout.removeTemporaryAttribute(.spellingState, forCharacterRange: whole)
        storage.removeAttribute(.toolTip, range: whole)
        guard marksAreCurrent else { return }
        let string = storage.string as NSString
        var searchFrom = 0
        for issue in issues {
            var range = string.range(of: issue.wrong, range: NSRange(location: searchFrom, length: string.length - searchFrom))
            if range.location == NSNotFound { range = string.range(of: issue.wrong) }
            guard range.location != NSNotFound else { continue }
            layout.addTemporaryAttribute(.spellingState, value: NSAttributedString.SpellingState.spelling.rawValue,
                                         forCharacterRange: range)
            storage.addAttribute(.toolTip, value: issue.why, range: range)
            searchFrom = NSMaxRange(range)
        }
    }

    func measureInput() {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        layout.ensureLayout(for: container)
        let height = max(26, ceil(layout.usedRect(for: container).height))
        if abs(height - inputHeight) > 0.5 {
            inputHeight = height
            onLayoutChange?(true)
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let textView else { return }
        input = textView.string
        textView.typingAttributes = Theme.textAttributes
        applyMarks()
        measureInput()
        scheduleSave()
    }

    /// Saves a moment after the last edit, so text typed into an open panel survives the app being quit.
    private var pendingSave: DispatchWorkItem?
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let flags = (textView as? InputNSTextView)?.keyFlags ?? NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                run()
            }
            return true
        }
        // Tab moves to the reply note instead of typing a tab character into the message.
        if selector == #selector(NSResponder.insertTab(_:)) || selector == #selector(NSResponder.insertBacktab(_:)) {
            if mode == .reply { noteFocusPending = true; focusNoteRequest += 1 }
            return true
        }
        return false
    }

    /// Debug: replaces the input as if the user had typed it.
    func simulateTyping(_ text: String) {
        guard let textView else { input = text; return }
        textView.string = text
        textDidChange(Notification(name: NSText.didChangeNotification))
    }

    var debugState: [String: Any] {
        ["mode": mode.rawValue, "input": input, "note": note, "resultsFor": resultsFor, "running": isRunning,
         "notice": notice ?? NSNull(), "noticeOpensSettings": noticeOpensSettings,
         "sharp": outputs[.sharp].map { ["body": $0.body, "highlights": $0.highlights, "error": $0.error ?? NSNull(), "streaming": $0.streaming] } ?? NSNull(),
         "chill": outputs[.chill].map { ["body": $0.body, "highlights": $0.highlights, "error": $0.error ?? NSNull(), "streaming": $0.streaming] } ?? NSNull(),
         "issues": issues.map { ["wrong": $0.wrong, "fix": $0.fix] }, "marksAreCurrent": marksAreCurrent, "isStale": isStale, "canUpdate": canUpdate, "ghosts": ghosts.count,
         "textViewString": textView?.string ?? NSNull(), "inputHeight": inputHeight, "pinned": pinned]
    }

    // MARK: Persistence ("reopening restores what I left")

    private struct Saved: Codable {
        var mode: Mode
        var input: String
        var note: String?
        var outputs: [String: VoiceOutput]
        var grammarRaw: String
        var resultsFor: String
        var resultsNote: String?
    }

    func save() {
        let saved = Saved(mode: mode, input: input, note: note,
                          outputs: Dictionary(uniqueKeysWithValues: outputs.map { ($0.key.rawValue, $0.value) }),
                          grammarRaw: grammarRaw, resultsFor: resultsFor, resultsNote: resultsNote)
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: "state") }
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: "state"),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        mode = saved.mode
        input = saved.input
        note = saved.note ?? ""
        outputs = Dictionary(uniqueKeysWithValues: saved.outputs.compactMap { key, value in
            Voice(rawValue: key).map {
                let cutOff = value.streaming && !value.raw.isEmpty ? "The answer was cut off. Press ↩ to try again." : nil
                return ($0, VoiceOutput(raw: value.raw, streaming: false, error: value.error ?? cutOff))
            }
        })
        // A run cut off before anything arrived leaves nothing worth showing.
        if outputs.values.allSatisfy({ $0.raw.isEmpty && $0.error == nil }) { outputs = [:] }
        grammarRaw = saved.grammarRaw
        resultsFor = saved.resultsFor
        resultsNote = saved.resultsNote ?? note.trimmingCharacters(in: .whitespacesAndNewlines)
        parseGrammar(final: true)
    }
}
