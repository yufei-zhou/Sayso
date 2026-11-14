import AppKit
import SwiftUI

enum AppPaths {
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sayso", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var mode: Mode
    var input: String
    var note: String
    var sharp: String
    var chill: String
    var grammar: String

    func body(_ voice: Voice) -> String { VoiceOutput(raw: voice == .sharp ? sharp : chill).body }
}

/// Everything Sayso has answered, newest first, in a JSON file under Application Support.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let limit = 2000

    @Published private(set) var entries: [HistoryEntry] = []
    private let url = AppPaths.support.appendingPathComponent("history.json")

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url) {
            if let saved = try? decoder.decode([HistoryEntry].self, from: data) {
                entries = saved
            } else {
                // Unreadable: keep it aside rather than overwrite it.
                try? FileManager.default.moveItem(at: url, to: url.deletingPathExtension().appendingPathExtension("damaged.json"))
            }
        }
    }

    /// Asking again about the same text in the same mode replaces the earlier record.
    func record(_ entry: HistoryEntry) {
        entries.removeAll { $0.mode == entry.mode && $0.input == entry.input && $0.note == entry.note }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// A highlighted expression, with the answer it came from.
struct Phrase: Identifiable {
    let id: String
    let text: String
    let sentence: String
    let voice: Voice
    let entry: HistoryEntry

    /// Every highlighted phrase in the history, newest first, each phrase once.
    static func all(in entries: [HistoryEntry]) -> [Phrase] {
        var seen = Set<String>()
        var result: [Phrase] = []
        for entry in entries {
            for voice in Voice.allCases {
                let output = VoiceOutput(raw: voice == .sharp ? entry.sharp : entry.chill)
                for phrase in output.highlights {
                    let key = String(VoiceOutput.fold(phrase))
                    guard seen.insert(key).inserted else { continue }
                    result.append(Phrase(id: key, text: phrase, sentence: output.body, voice: voice, entry: entry))
                }
            }
        }
        return result
    }
}

struct HistoryView: View {
    @ObservedObject var store = HistoryStore.shared
    @State private var query = ""
    @AppStorage("historyShowsPhrases") private var showPhrases = false
    @State private var confirmClear = false
    let open: (HistoryEntry) -> Void

    private var shown: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.entries }
        return store.entries.filter {
            [$0.input, $0.note, $0.sharp, $0.chill].contains { $0.lowercased().contains(q) }
        }
    }

    private var phrases: [Phrase] {
        let all = Phrase.all(in: store.entries)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.text.lowercased().contains(q) || $0.sentence.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                PillSwitch(options: [(false, "History"), (true, "Phrases")], selection: $showPhrases)
                Image(systemName: "magnifyingglass").foregroundStyle(Color.inkTertiary).padding(.leading, 6)
                TextField("Search", text: $query).textFieldStyle(.plain).font(.system(size: 14))
                if !store.entries.isEmpty, !showPhrases {
                    Button(confirmClear ? "Clear all?" : "Clear") {
                        if confirmClear { store.clear(); confirmClear = false } else { confirmClear = true }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(confirmClear ? Color(nsColor: Theme.error) : Color.inkSecondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            Rectangle().fill(Color.hairline).frame(height: 1)
            if showPhrases {
                if phrases.isEmpty {
                    Text(store.entries.isEmpty ? "Nothing here yet" : "No matches")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.inkTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(phrases) { phrase in
                                PhraseRow(phrase: phrase)
                                    .contentShape(Rectangle())
                                    .onTapGesture { open(phrase.entry) }
                                Rectangle().fill(Color.hairline).frame(height: 1).padding(.leading, 18)
                            }
                        }
                    }
                }
            } else if shown.isEmpty {
                Text(store.entries.isEmpty ? "Nothing here yet" : "No matches")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.inkTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { entry in
                            HistoryRow(entry: entry)
                                .contentShape(Rectangle())
                                .onTapGesture { open(entry) }
                                .contextMenu {
                                    Button("Delete") { store.delete(entry.id) }
                                }
                            Rectangle().fill(Color.hairline).frame(height: 1).padding(.leading, 18)
                        }
                    }
                }
            }
        }
        .background(Color.paper)
        .onChange(of: query) { _, _ in confirmClear = false }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(entry.mode.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.well))
                Text(entry.date, format: .relative(presentation: .named))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.inkTertiary)
            }
            Text(entry.input)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.ink)
                .lineLimit(2)
            ForEach(Voice.allCases, id: \.self) { voice in
                let text = entry.body(voice)
                if !text.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle().fill(Color(nsColor: voice == .sharp ? Theme.sharp : Theme.chill)).frame(width: 5, height: 5)
                        Text(text).font(.system(size: 13)).foregroundStyle(Color.inkSecondary).lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(hover ? Color.well.opacity(0.6) : .clear)
        .onHover { hover = $0 }
    }
}

private struct PhraseRow: View {
    let phrase: Phrase
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(phrase.text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(nsColor: phrase.voice == .sharp ? Theme.sharp : Theme.chill))
            Text(phrase.sentence)
                .font(.system(size: 13))
                .foregroundStyle(Color.inkSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(hover ? Color.well.opacity(0.6) : .clear)
        .onHover { hover = $0 }
    }
}
