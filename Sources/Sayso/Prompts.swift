import Foundation

enum Mode: String, CaseIterable, Codable {
    case polish, reply, zh

    /// What goes in the empty input box.
    var placeholder: String {
        switch self {
        case .polish: "Write or paste your English"
        case .reply: "Paste the message you're replying to"
        case .zh: "Write in Chinese"
        }
    }

    var title: String {
        switch self {
        case .polish: "Polish"
        case .reply: "Reply"
        case .zh: "中 → En"
        }
    }
}

enum Voice: String, CaseIterable, Codable {
    case sharp, chill

    var title: String { rawValue.uppercased() }
}

/// One editable prompt file. Defaults ship in the app bundle (Resources/prompts, the same files the eval
/// scripts use); an edited copy in Application Support/Sayso/prompts takes precedence.
struct PromptFile: Identifiable, Hashable {
    let id: String
    let title: String

    static let all = [
        PromptFile(id: "polish.md", title: "Polish"),
        PromptFile(id: "reply.md", title: "Reply"),
        PromptFile(id: "zh.md", title: "中 → En"),
        PromptFile(id: "_sharp.md", title: "Sharp voice"),
        PromptFile(id: "_chill.md", title: "Chill voice"),
        PromptFile(id: "_format.md", title: "Output format"),
        PromptFile(id: "grammar.md", title: "Grammar check"),
    ]

    static let defaultsDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["SAYSO_PROMPTS"] {
            return URL(fileURLWithPath: override)
        }
        return Bundle.main.resourceURL!.appendingPathComponent("prompts")
    }()

    static let customDirectory: URL = {
        let url = AppPaths.support.appendingPathComponent("prompts", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private var customURL: URL { Self.customDirectory.appendingPathComponent(id) }

    var defaultText: String { (try? String(contentsOf: Self.defaultsDirectory.appendingPathComponent(id), encoding: .utf8)) ?? "" }
    var isCustomized: Bool { FileManager.default.fileExists(atPath: customURL.path) }
    var text: String { isCustomized ? ((try? String(contentsOf: customURL, encoding: .utf8)) ?? defaultText) : defaultText }

    /// Saves an edit; text identical to the default removes the custom copy.
    func save(_ text: String) {
        if text == defaultText {
            try? FileManager.default.removeItem(at: customURL)
        } else {
            try? text.write(to: customURL, atomically: true, encoding: .utf8)
        }
    }

    /// Back to the shipped prompt, keeping the edited version beside it as a backup.
    func restoreDefault() {
        guard isCustomized else { return }
        let backup = Self.customDirectory.appendingPathComponent(id + ".backup")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: customURL, to: backup)
    }
}

/// Builds requests from the prompt files: task file (lines tagged [sharp]/[chill] kept only for that voice) +
/// voice file + output format. Files are read on every request, so edits apply right away. (Few-shot examples were
/// dropped on 2026-11-11: a blind comparison showed they no longer improved the answers; see eval/README.md, round 6.)
enum Prompts {
    private static func read(_ name: String) -> String {
        (PromptFile.all.first { $0.id == name }?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func instructions(mode: Mode, voice: Voice) -> String {
        let tag = #/\[(sharp|chill)\] ?(.*)/#
        let task = read("\(mode.rawValue).md").components(separatedBy: "\n").compactMap { line -> String? in
            guard let match = line.wholeMatch(of: tag) else { return line }
            return match.output.1 == voice.rawValue ? String(match.output.2) : nil
        }.joined(separator: "\n")
        return task + "\n\n" + read("_\(voice.rawValue).md") + "\n\n" + read("_format.md")
    }

    /// Reply mode sends the received message and the user's optional note in a labelled form the prompt describes.
    static func userTurn(mode: Mode, text: String, note: String) -> String {
        guard mode == .reply else { return text }
        return "Message:\n\(text)" + (note.isEmpty ? "" : "\n\nMy note: \(note)")
    }

    static func input(mode: Mode, voice: Voice, text: String, note: String = "") -> [[String: String]] {
        [["role": "user", "content": userTurn(mode: mode, text: text, note: note)]]
    }

    static var grammar: String { read("grammar.md") }
}
