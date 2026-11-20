import AppKit
import ServiceManagement
import SwiftUI

extension Keychain {
    /// The last four characters of the saved key (read from this launch's cache or the Keychain, which the app owns).
    static var savedKeyTail: String? {
        guard hasKey else { return nil }
        if let test = ProcessInfo.processInfo.environment["SAYSO_API_KEY"] { return test.isEmpty ? nil : String(test.suffix(4)) }
        return readKey().map { String($0.suffix(4)) }
    }

    /// Checks for a stored key without reading it (no Keychain prompt).
    static var hasKey: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Sayso",
            kSecAttrAccount as String: "openai",
            kSecReturnAttributes as String: true,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}

/// The settings window: one pane, sized to fit.
struct SettingsView: View {
    let onSize: (CGSize) -> Void

    var body: some View {
        GeneralSettings().frame(width: 500)
            .fixedSize()
            .background(GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size, initial: true) { _, size in onSize(size) }
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.well)
    }
}

// MARK: - General

/// A white rounded group of rows, like System Settings.
private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.paper))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.03), radius: 2, y: 1)
    }
}

/// Icon tile, label, and the control on the right.
private struct Row<Trailing: View>: View {
    let symbol: String
    let tint: NSColor
    let title: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: tint).gradient))
            Text(title).font(.system(size: 13)).foregroundStyle(Color.ink)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
    }
}

private struct RowDivider: View {
    var body: some View { Rectangle().fill(Color.hairline).frame(height: 1).padding(.leading, 49) }
}

/// A small pill switch matching the panel's mode switch.
struct PillSwitch<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                let on = value == selection
                Text(title)
                    .font(.system(size: 12, weight: on ? .medium : .regular))
                    .foregroundStyle(on ? Color.ink : Color.inkSecondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 4)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.paper)
                                .shadow(color: .black.opacity(0.10), radius: 1, y: 0.5)
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy(duration: 0.22)) { selection = value } }
            }
        }
        .padding(2.5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.well))
    }
}

private struct GeneralSettings: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var key = ""
    @State private var hasKey = Keychain.hasKey
    /// The last four characters of the saved key, so it's clear a key is there (and which one).
    @State private var keyTail = Keychain.savedKeyTail
    @State private var saved = false
    @State private var inputMonitoring = HotkeyMonitor.hasPermission
    @State private var accessibility = Selection.isTrusted
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            Card { ShortcutRecorder() }
            Card {
                Row(symbol: "key.fill", tint: NSColor(hex: 0xE8A317), title: "OpenAI API key") { keyField }
                RowDivider()
                Row(symbol: "sparkles", tint: NSColor(hex: 0x12876A), title: "Model") {
                    PillSwitch(options: ModelOption.all.map { ($0.id, $0.name) }, selection: $settings.modelID)
                }
            }
            Card {
                Row(symbol: "power", tint: NSColor(hex: 0x6E6E7A), title: "Open at login") {
                    Toggle("", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }
            if !inputMonitoring || !accessibility {
                Card {
                    if !inputMonitoring {
                        Row(symbol: "keyboard", tint: Theme.error, title: "Input Monitoring") {
                            Button("Open Settings") {
                                HotkeyMonitor.requestPermission()
                                openPrivacy("Privacy_ListenEvent")
                            }
                            .controlSize(.small)
                        }
                    }
                    if !inputMonitoring, !accessibility { RowDivider() }
                    if !accessibility {
                        Row(symbol: "hand.raised.fill", tint: Theme.error, title: "Accessibility") {
                            Button("Open Settings") { Selection.requestTrust() }.controlSize(.small)
                        }
                    }
                }
            }
        }
        .padding(20)
        .onReceive(timer) { _ in
            inputMonitoring = HotkeyMonitor.hasPermission
            accessibility = Selection.isTrusted
        }
    }

    private var keyField: some View {
        HStack(spacing: 6) {
            if hasKey, key.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: Theme.fixed))
                    .help("Saved in the Keychain. Paste a new key to replace it.")
                    .transition(.scale.combined(with: .opacity))
            }
            SecureField("", text: $key, prompt: Text(hasKey ? keyTail.map { "sk-…\($0)" } ?? "Saved" : "Paste your key"))
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 9)
                // The field gives up some width while the Save button is showing, so the row never gets squeezed.
                .frame(width: key.isEmpty ? 210 : 158, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.well))
                .onSubmit(saveKey)
                .onChange(of: key) { _, _ in withAnimation { saved = false } }
            if !key.isEmpty {
                Button(action: saveKey) {
                    Text("Save")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .frame(height: 22)
                        .background(Capsule().fill(Color(nsColor: NSColor(hex: 0x534AB7))))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: key.isEmpty)
        // Debug (test launches only): fills the field so the Save button can be looked at; nothing is saved.
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SaysoDebugFillKey"))) { note in
            key = note.object as? String ?? ""
        }
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {}
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func saveKey() {
        guard !key.isEmpty, Keychain.saveKey(key) else { return }
        key = ""
        hasKey = true
        keyTail = Keychain.savedKeyTail
        withAnimation(.snappy) { saved = true }
    }

    private func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Shortcut recorder

/// Click, then press the shortcut. Press the same keys twice quickly for a double-press shortcut (⌃X X).
/// Esc cancels. Shortcuts that can't work are refused with the reason; risky ones are saved with a warning.
private struct ShortcutRecorder: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var recording = false
    @State private var held: NSEvent.ModifierFlags = []
    @State private var pending: Hotkey?
    @State private var refused: (hotkey: Hotkey, conflicts: [HotkeyConflict])?
    @State private var monitor: Any?
    @State private var finishWork: DispatchWorkItem?
    @State private var hover = false
    @State private var infoShown = false
    /// When a click ended the recording: the same click then reaches the field and must not start a new one.
    @State private var stoppedByClick = Date.distantPast
    /// Recording a modifier tapped on its own: when it went down, and the previous clean tap.
    @State private var modifierDown: (flag: NSEvent.ModifierFlags, time: Date)?
    @State private var modifierTap: (flag: NSEvent.ModifierFlags, time: Date)?

    private var shown: Hotkey? { recording ? pending : (refused?.hotkey ?? settings.hotkey) }
    private var conflicts: [HotkeyConflict] {
        if recording { return [] }
        return refused?.conflicts ?? HotkeyConflicts.check(settings.hotkey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Row(symbol: "command", tint: NSColor(hex: 0x534AB7), title: "Shortcut") {
                HStack(spacing: 8) {
                    if let note = conflicts.first(where: { $0.level == .info }), !recording {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(infoShown ? Color.inkSecondary : Color.inkTertiary)
                            .contentShape(Rectangle())
                            .onHover { infoShown = $0 }
                            .onTapGesture { infoShown.toggle() }
                            .popover(isPresented: $infoShown, arrowEdge: .bottom) {
                                Text(note.message)
                                    .font(.system(size: 12))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(width: 220, alignment: .leading)
                                    .padding(10)
                            }
                    }
                    if settings.hotkey != .default, !recording, refused == nil {
                        Button {
                            refused = nil
                            settings.hotkey = .default
                        } label: {
                            Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.inkTertiary)
                        .help("Reset to \(Hotkey.default.display)")
                    }
                    field
                }
            }
            let visible = conflicts.filter { $0.level != .info }
            if !visible.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, conflict in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: icon(conflict.level))
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(conflict.message)
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(color(conflict.level))
                    }
                }
                .padding(.leading, 49)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
                .padding(.top, -4)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: conflicts)
        .onDisappear(perform: stop)
    }

    private var field: some View {
        HStack(spacing: 5) {
            if let hotkey = shown {
                KeyCaps(hotkey: hotkey)
            } else if !held.isEmpty {
                KeyCaps(hotkey: Hotkey(keyCode: 0, modifiers: held.rawValue, doubleTap: false, key: ""))
            } else {
                Text("Type shortcut")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: Theme.sharp))
            }
        }
        .frame(minWidth: 120, minHeight: 30)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(recording ? Color(nsColor: Theme.sharpWash) : (hover ? Color.well : Color.well.opacity(0.6)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(recording ? Color(nsColor: Theme.sharp) : (refused != nil ? Color(nsColor: Theme.error).opacity(0.6) : .clear),
                              lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            if recording { stop() } else if Date().timeIntervalSince(stoppedByClick) > 0.3 { start() }
        }
        .animation(.easeOut(duration: 0.15), value: recording)
        .help(recording ? "" : "Click, then press a shortcut. Press it twice for a double-press shortcut, or tap ⌘, ⌥, ⌃ or ⇧ twice on its own.")
    }

    private func start() {
        refused = nil
        pending = nil
        held = []
        recording = true
        settings.recordingHotkey = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { event in
            handle(event)
        }
    }

    private func stop() {
        finishWork?.cancel()
        modifierDown = nil
        modifierTap = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        pending = nil
        held = []
        if settings.recordingHotkey { settings.recordingHotkey = false }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            stoppedByClick = Date()
            stop()
            return event
        case .flagsChanged:
            let now = event.modifierFlags.intersection(Hotkey.relevant)
            let single = [NSEvent.ModifierFlags.command, .control, .option, .shift].first { $0 == now }
            if held.isEmpty, let single {
                modifierDown = (single, Date())
            } else if now.isEmpty, let down = modifierDown, held == down.flag, Date().timeIntervalSince(down.time) < 0.4 {
                // A clean tap of one modifier; two in a row record "that modifier, twice".
                if let tap = modifierTap, tap.flag == down.flag, Date().timeIntervalSince(tap.time) < 0.45 {
                    held = []
                    commit(.modifierTap(down.flag))
                    return nil
                }
                modifierTap = (down.flag, Date())
                modifierDown = nil
            } else {
                modifierDown = nil
            }
            held = now
            return nil
        default:
            break
        }
        let flags = event.modifierFlags.intersection(Hotkey.relevant)
        modifierDown = nil
        modifierTap = nil
        if Int(event.keyCode) == 53, flags.isEmpty { stop(); return nil } // Esc
        guard !event.isARepeat else { return nil }
        let candidate = Hotkey(keyCode: event.keyCode, modifiers: flags.rawValue, doubleTap: false, key: Hotkey.keyName(for: event))
        if let first = pending, first.keyCode == candidate.keyCode, first.modifiers == candidate.modifiers {
            var double = candidate
            double.doubleTap = true
            commit(double)
        } else {
            pending = candidate
            finishWork?.cancel()
            let work = DispatchWorkItem { commit(candidate) }
            finishWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
        return nil
    }

    private func commit(_ hotkey: Hotkey) {
        finishWork?.cancel()
        let found = HotkeyConflicts.check(hotkey)
        stop()
        if found.contains(where: { $0.level == .error }) {
            refused = (hotkey, found)
            // Show why for a moment, then go back to the shortcut that is really in use.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if refused?.hotkey == hotkey, !recording { withAnimation(.easeOut(duration: 0.2)) { refused = nil } }
            }
        } else {
            refused = nil
            settings.hotkey = hotkey
        }
    }

    private func icon(_ level: HotkeyConflict.Level) -> String {
        switch level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func color(_ level: HotkeyConflict.Level) -> Color {
        switch level {
        case .info: .inkTertiary
        case .warning: Color(nsColor: .systemOrange)
        case .error: Color(nsColor: Theme.error)
        }
    }
}

/// A shortcut drawn as keyboard keys: ⌃ X, with a "×2" mark for double presses.
struct KeyCaps: View {
    let hotkey: Hotkey

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(hotkey.modifierSymbols.enumerated()), id: \.offset) { _, symbol in cap(symbol) }
            if !hotkey.key.isEmpty { cap(hotkey.key) }
            if hotkey.doubleTap {
                Text("×2")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(nsColor: Theme.sharp))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(nsColor: Theme.sharpHighlight)))
            }
        }
    }

    private func cap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Color.ink)
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, label.count > 1 ? 6 : 0)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.hairline, lineWidth: 1))
    }
}
