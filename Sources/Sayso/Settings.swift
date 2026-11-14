import Foundation
import Security

/// The OpenAI key lives only in the Keychain (service "Sayso", account "openai").
enum Keychain {
    private static let service = "Sayso"
    private static let account = "openai"

    /// Read once per launch, so the Keychain is asked (and may prompt) only the first time.
    nonisolated(unsafe) private static var cached: String?
    private static let lock = NSLock()

    static func readKey() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        cached = readFromKeychain()
        // A key stored by another tool (e.g. the `security` command) belongs to that tool, so macOS asks again
        // whenever this app is rebuilt. Storing it once under the app's own name ends those prompts.
        if let key = cached, !UserDefaults.standard.bool(forKey: "keychainOwnedByApp"), store(key) {
            UserDefaults.standard.set(true, forKey: "keychainOwnedByApp")
        }
        return cached
    }

    private static func readFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    static func saveKey(_ key: String) -> Bool {
        let clean = key.filter { !$0.isWhitespace }
        lock.lock()
        cached = nil
        lock.unlock()
        return store(clean)
    }

    /// Replaces the stored key with one owned by this app.
    private static func store(_ clean: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !clean.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(clean.utf8)
        for _ in 0..<3 where SecItemAdd(add as CFDictionary, nil) == errSecSuccess { return true }
        return false
    }
}

/// A model choice and the lowest reasoning effort it accepts (lower is faster here; quality was measured at these).
struct ModelOption: Identifiable, Hashable {
    let id: String
    let name: String
    let effort: String

    static let all = [
        ModelOption(id: "gpt-6.1-sol", name: "Sol", effort: "low"),
        ModelOption(id: "gpt-6.1-terra", name: "Terra", effort: "low"),
        ModelOption(id: "gpt-6-luna", name: "Luna", effort: "none"),
    ]
    static let `default` = all[0]
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var modelID: String {
        didSet { UserDefaults.standard.set(modelID, forKey: "model") }
    }

    var model: ModelOption { ModelOption.all.first { $0.id == modelID } ?? .default }

    @Published var hotkey: Hotkey {
        didSet {
            if let data = try? JSONEncoder().encode(hotkey) { UserDefaults.standard.set(data, forKey: "hotkey") }
            onHotkeyChange?()
        }
    }
    var onHotkeyChange: (() -> Void)?
    /// Set while the shortcut recorder is listening.
    @Published var recordingHotkey = false {
        didSet { onHotkeyChange?() }
    }

    private init() {
        modelID = UserDefaults.standard.string(forKey: "model") ?? ModelOption.default.id
        var saved = UserDefaults.standard.data(forKey: "hotkey").flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) } ?? .default
        // ⌘ ⌘ became the default in 1.0.1. Whoever still had the old default (never chose a shortcut) moves over, once.
        if !UserDefaults.standard.bool(forKey: "hotkeyDefaultMovedToCommandTap") {
            UserDefaults.standard.set(true, forKey: "hotkeyDefaultMovedToCommandTap")
            if saved == .previousDefault { saved = .default }
        }
        hotkey = saved
    }
}
