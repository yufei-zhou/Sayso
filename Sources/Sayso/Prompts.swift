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

/// The prompt files ship in the app bundle (Resources/prompts, the same files the eval scripts use).
/// `SAYSO_PROMPTS` points at another folder (eval and tests only).
enum PromptFiles {
    static let directory: URL = {
        if let override = ProcessInfo.processInfo.environment["SAYSO_PROMPTS"] {
            return URL(fileURLWithPath: override)
        }
        return Bundle.main.resourceURL!.appendingPathComponent("prompts")
    }()
}

/// Builds requests from the prompt files: task file (lines tagged [sharp]/[chill] kept only for that voice) +
/// voice file + output format. (Few-shot examples were
/// dropped on 2026-11-11: a blind comparison showed they no longer improved the answers; see eval/README.md, round 6.)
enum Prompts {
    private static func read(_ name: String) -> String {
        ((try? String(contentsOf: PromptFiles.directory.appendingPathComponent(name), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
