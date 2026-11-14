import AppKit
import SwiftUI

/// A small event log for troubleshooting (never the text itself): ~/Library/Application Support/Sayso/debug/events.log
enum DebugLog {
    static func write(_ line: String) {
        let dir = AppPaths.support.appendingPathComponent("debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("events.log")
        let entry = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate!
    let panel = PanelController()
    private let hotkey = HotkeyMonitor()
    private let carbonHotkey = CarbonHotkey()
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one Sayso at a time (an older copy still running would answer the shortcut too): the newest wins.
        let me = NSRunningApplication.current
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.nano.Sayso")
        where other.processIdentifier != me.processIdentifier {
            DebugLog.write("launch: closing an older copy (pid \(other.processIdentifier))")
            other.terminate()
        }
        installMenu()
        hotkey.onTrigger = { [weak self] in MainActor.assumeIsolated { self?.trigger() } }
        carbonHotkey.onPress = { [weak self] in MainActor.assumeIsolated { self?.trigger() } }
        AppSettings.shared.onHotkeyChange = { [weak self] in self?.applyHotkey() }
        applyHotkey()
        hotkey.onEscape = { [weak self] in MainActor.assumeIsolated { self?.panel.escapePressedElsewhere() } }
        DebugLog.write("launch: inputMonitoring=\(HotkeyMonitor.hasPermission) accessibility=\(Selection.isTrusted) hotkey=\(AppSettings.shared.hotkey.display)")
        // `--no-prompts` (used when testing) skips the permission dialogs and the first-run settings window.
        let quiet = CommandLine.arguments.contains("--no-prompts")
        if !hotkey.start() {
            if !quiet { HotkeyMonitor.requestPermission() }
            hotkey.startWhenPermitted()
        }
        if !quiet, !Selection.isTrusted { Selection.requestTrust() }
        if !quiet, !Keychain.hasKey { showSettings() }
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    /// The menu bar never shows (Sayso has no Dock icon), but its key equivalents are what make ⌘A, ⌘C, ⌘V, ⌘Z and
    /// ⌘W work in text fields and windows.
    private func installMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            return item
        }
        let settings = item("Settings…", #selector(openSettingsFromMenu), ",")
        settings.target = self
        // ⌘Q quits from the Settings and History windows. In the panel it only closes the panel (PanelController
        // catches it first), so a slip of the fingers doesn't switch the shortcut off.
        submenu("Sayso", [settings, .separator(), item("Quit Sayso", #selector(NSApplication.terminate(_:)), "q")])
        submenu("File", [item("Close Window", #selector(NSWindow.performClose(_:)), "w")])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item("Delete", #selector(NSText.delete(_:)), ""),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        NSApp.mainMenu = main
    }

    @objc private func openSettingsFromMenu() { showSettings() }

    /// Double presses go through the event tap; single presses are registered with the system so the keys don't
    /// also reach the frontmost app. Nothing fires while a new shortcut is being recorded.
    private func applyHotkey() {
        let settings = AppSettings.shared
        hotkey.paused = settings.recordingHotkey
        if settings.hotkey.doubleTap {
            hotkey.doubleTap = settings.hotkey
            carbonHotkey.unregister()
        } else {
            hotkey.doubleTap = nil
            if settings.recordingHotkey {
                carbonHotkey.unregister()
            } else if !carbonHotkey.register(settings.hotkey) {
                DebugLog.write("hotkey: \(settings.hotkey.display) could not be registered (another app holds it)")
            }
        }
    }

    /// The shortcut: with text selected in another app, start on it; otherwise show the panel as it was left, or
    /// close it if it has the keyboard.
    func trigger() {
        if panel.isKey {
            DebugLog.write("trigger: panel has the keyboard, closing it")
            panel.hide()
            return
        }
        guard !copyingSelection else { return }
        let selection = Selection.current()
        // An app that tells assistive software nothing about selections is asked to copy instead (and the
        // clipboard is put back). Apps that do answer are believed when they say nothing is selected.
        if selection == nil, Selection.isTrusted, !Selection.lastWasConclusive,
           let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            readByCopying(pid: app.processIdentifier, bundleID: app.bundleIdentifier, takeFocus: true)
            return
        }
        finishTrigger(selection, report: Selection.lastReport, takeFocus: true)
    }

    private var copyingSelection = false

    private func readByCopying(pid: pid_t, bundleID: String?, takeFocus: Bool) {
        let report = Selection.lastReport
        copyingSelection = true
        ClipboardBridge.copySelection(pid: pid, bundleID: bundleID, focusedRole: Selection.lastFocusedRole) { [weak self] copied in
            guard let self else { return }
            self.copyingSelection = false
            let result = copied.map { Selection.Result(text: $0.text, editable: $0.editable, element: nil, pid: pid) }
            self.finishTrigger(result, report: report + "; by copying: " + ClipboardBridge.lastReport, takeFocus: takeFocus)
        }
    }

    private func finishTrigger(_ selection: Selection.Result?, report: String, takeFocus: Bool) {
        DebugLog.write("trigger: hotkey=\(AppSettings.shared.hotkey.display) "
                       + (selection.map { "selection=\($0.text.count) chars editable=\($0.editable)" } ?? "selection=none")
                       + " (\(report)) panelVisible=\(panel.isVisible)")
        if let selection {
            panel.show(text: selection.text, editable: selection.editable, element: selection.element, pid: selection.pid,
                       takeFocus: takeFocus)
        } else if panel.isVisible, !panel.model.pinned {
            panel.hide()
        } else {
            panel.show(text: nil, editable: nil, takeFocus: takeFocus)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        panel.model.save()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show(text: nil, editable: nil)
        return false
    }

    private let settingsToolbar = SettingsToolbar()

    func showSettings(activate: Bool = true) {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = SettingsTab.current.title
            window.toolbarStyle = .preference
            settingsToolbar.window = window
            window.toolbar = settingsToolbar.make()
            window.backgroundColor = Theme.well
            let host = NSHostingView(rootView: SettingsView { [weak self] size in self?.fitSettings(to: size) })
            host.sizingOptions = []
            window.contentView = host
            window.isReleasedWhenClosed = false
            settingsWindow = window
            window.center()
        }
        present(settingsWindow, activate: activate)
        // Don't start with the cursor in the API key field.
        DispatchQueue.main.async { [weak self] in self?.settingsWindow?.makeFirstResponder(nil) }
    }

    /// Resizes the settings window to its pane, keeping the top edge where it is.
    private func fitSettings(to size: CGSize) {
        guard let window = settingsWindow, size.width > 0, size.height > 0 else { return }
        let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        guard abs(target.width - window.frame.width) > 0.5 || abs(target.height - window.frame.height) > 0.5 else { return }
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.origin.x += (frame.width - target.width) / 2
        frame.size = target
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    func showHistory(activate: Bool = true) {
        if historyWindow == nil {
            historyWindow = makeWindow(title: "History", size: NSSize(width: 520, height: 620), resizable: true,
                                       view: HistoryView { [weak self] entry in self?.open(entry: entry) })
        }
        present(historyWindow, activate: activate)
    }

    func open(entry: HistoryEntry) {
        panel.model.load(entry: entry)
        panel.show(text: nil, editable: nil)
    }

    private func makeWindow<V: View>(title: String, size: NSSize, resizable: Bool, view: V) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow?, activate: Bool) {
        guard activate else { window?.orderFrontRegardless(); return }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Debug hooks for testing without the keyboard or clipboard (see TESTING.md):
    ///   sayso://show?text=…&mode=polish|reply|zh&note=…   (shows without taking focus)
    ///   sayso://snapshot?path=/tmp/x.png
    ///   sayso://hide
    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        // Any app or web page can open a sayso:// link, and these hooks write files and start requests, so they
        // only exist in a copy started for testing (SAYSO_DEBUG_HOOKS=1). Otherwise a link does nothing.
        guard ProcessInfo.processInfo.environment["SAYSO_DEBUG_HOOKS"] == "1" else { return }
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let components = URLComponents(string: string) else { return }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        switch components.host {
        case "show":
            let text = query["text"]
            if let text { panel.model.load(text: text, editable: nil) }
            if let mode = query["mode"].flatMap(Mode.init(rawValue:)) { panel.model.mode = mode }
            if let note = query["note"] { panel.model.note = note }
            panel.show(text: nil, editable: nil, takeFocus: false)
            if text != nil { panel.model.runSelection() }
        case "snapshot":
            if let path = query["path"] { panel.snapshot(to: URL(fileURLWithPath: path)) }
        case "hide":
            panel.hide()
        case "history":
            showHistory(activate: false)
        case "settings":
            if let tab = query["tab"].flatMap(SettingsTab.init(rawValue:)) {
                UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab")
                settingsWindow?.toolbar?.selectedItemIdentifier = tab.identifier
                settingsWindow?.title = tab.title
            }
            showSettings(activate: false)
            // &key=… types into the API key field (it is never saved by this).
            if let key = query["key"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(name: Notification.Name("SaysoDebugFillKey"), object: key)
                }
            }
        case "type":
            // sayso://type?text=… — edits the input as if typed.
            panel.model.simulateTyping(query["text"] ?? "")
        case "key":
            // sayso://key?k=n — ⌘N etc.
            DebugLog.write("debug key ⌘\(query["k"] ?? "") handled=\(panel.simulateCommand(query["k"] ?? ""))")
        case "keydown":
            // sayso://keydown?code=53&chars=…&mods=shift,control&focus=1 — a key press into the panel's focused view.
            if query["focus"] != nil { panel.model.focusInput() }
            var mods: NSEvent.ModifierFlags = []
            for name in (query["mods"] ?? "").split(separator: ",") {
                switch name {
                case "shift": mods.insert(.shift)
                case "control": mods.insert(.control)
                case "option": mods.insert(.option)
                case "command": mods.insert(.command)
                default: break
                }
            }
            let code = UInt16(query["code"] ?? "") ?? 0
            let defaults: [UInt16: String] = [53: "\u{1B}", 36: "\r", 48: "\t"]
            panel.simulateKeyDown(code: code, characters: query["chars"] ?? defaults[code] ?? "", modifiers: mods)
        case "appearance":
            // sayso://appearance?name=dark|light|auto — Sayso's own windows only.
            switch query["name"] {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: NSApp.appearance = nil
            }
        case "ax-probe":
            // sayso://ax-probe?path=… — what each running app exposes about its text selection (no text, lengths only).
            if let path = query["path"],
               let data = try? JSONSerialization.data(withJSONObject: Selection.probe(), options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        case "ax-read":
            // sayso://ax-read?pid=…&path=…[&replace=…] — reads one app's selection (length only), optionally replaces it.
            if let pid = Int32(query["pid"] ?? ""), let path = query["path"] {
                let result = Selection.read(pid: pid, name: "pid \(pid)")
                var report: [String: Any] = ["found": result != nil, "length": result?.text.count ?? 0,
                                             "editable": result?.editable ?? false, "report": Selection.lastReport]
                if query["web"] != nil { report["webAreaLength"] = Selection.readWebArea(pid: pid)?.count ?? -1 }
                if let replacement = query["replace"], let result, let element = result.element {
                    report["replaced"] = Selection.replace(in: element, original: result.text, with: replacement)
                }
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
        case "ax-copy":
            // sayso://ax-copy?pid=…&path=… — asks one app to copy its selection, reports the length, restores the clipboard.
            if let pid = Int32(query["pid"] ?? ""), let path = query["path"] {
                _ = Selection.read(pid: pid, name: "pid \(pid)")
                let conclusive = Selection.lastWasConclusive
                ClipboardBridge.copySelection(pid: pid, bundleID: nil, focusedRole: Selection.lastFocusedRole) { copied in
                    let report: [String: Any] = ["found": copied != nil, "length": copied?.text.count ?? 0, "editable": copied?.editable ?? false,
                                                 "accessibilityConclusive": conclusive, "report": ClipboardBridge.lastReport]
                    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                        try? data.write(to: URL(fileURLWithPath: path))
                    }
                }
            }
        case "select":
            // sayso://select?pid=… — the shortcut's path for one given app, without taking the keyboard.
            if let pid = Int32(query["pid"] ?? "") {
                let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                let selection = Selection.read(pid: pid, name: "pid \(pid)")
                if selection == nil, !Selection.lastWasConclusive {
                    readByCopying(pid: pid, bundleID: bundleID, takeFocus: false)
                } else {
                    finishTrigger(selection, report: Selection.lastReport, takeFocus: false)
                }
            }
        case "replace":
            // sayso://replace?voice=sharp|chill — what the Replace button does.
            if let voice = Voice(rawValue: query["voice"] ?? ""), let body = panel.model.outputs[voice]?.body {
                panel.model.replaceOriginal(with: body, willPaste: { [weak self] in self?.panel.hide() }) { replaced in
                    DebugLog.write("debug replace: \(replaced)")
                }
            }
        case "menukey":
            // sayso://menukey?k=q — ⌘<key> offered to the (hidden) main menu, as when a Sayso window other than the panel has the keyboard.
            if let key = query["k"], let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                                 windowNumber: 0, context: nil, characters: key,
                                                                 charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0) {
                DebugLog.write("debug menu ⌘\(key) handled=\(NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)")
            }
        case "trigger":
            trigger()
        case "run":
            panel.model.run()
        case "state":
            // sayso://state?path=… — the panel's and model's state as JSON.
            var state = panel.model.debugState
            state["panel"] = panel.debugState
            state["settingsFrame"] = settingsWindow.map { NSStringFromRect($0.frame) } ?? NSNull()
            state["historyCount"] = HistoryStore.shared.entries.count
            state["clipboardChangeCount"] = NSPasteboard.general.changeCount
            state["canReplace"] = panel.model.canReplace
            state["windows"] = ["panel": panel.windowNumber, "settings": settingsWindow?.windowNumber ?? 0,
                                "history": historyWindow?.windowNumber ?? 0]
            if let path = query["path"], let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        case "open-history":
            // sayso://open-history?index=0 — shows a past result without taking focus.
            let index = Int(query["index"] ?? "0") ?? 0
            if HistoryStore.shared.entries.indices.contains(index) {
                panel.model.load(entry: HistoryStore.shared.entries[index])
                panel.show(text: nil, editable: nil, takeFocus: false)
            }
        case "check-hotkeys":
            // sayso://check-hotkeys?path=… — conflict report for a few sample shortcuts.
            let samples: [(UInt16, NSEvent.ModifierFlags, Bool, String)] = [
                (49, .command, false, "Space"), (49, .control, false, "Space"), (49, .option, false, "Space"),
                (12, .command, true, "Q"), (8, .command, true, "C"), (7, .control, true, "X"), (7, [], true, "X"),
                (14, [.control, .command], false, "E"),
            ]
            let report = samples.map { code, flags, double, key in
                let hotkey = Hotkey(keyCode: code, modifiers: flags.rawValue, doubleTap: double, key: key)
                let found = HotkeyConflicts.check(hotkey).map { "  [\($0.level)] \($0.message)" }
                return hotkey.display + (found.isEmpty ? "  (no conflicts)" : "\n" + found.joined(separator: "\n"))
            }.joined(separator: "\n")
            if let path = query["path"] { try? report.write(toFile: path, atomically: true, encoding: .utf8) }
        case "close-windows":
            historyWindow?.orderOut(nil)
            settingsWindow?.orderOut(nil)
        case "window-snapshot":
            // sayso://window-snapshot?name=history|settings&path=…
            let window = query["name"] == "history" ? historyWindow : settingsWindow
            if let view = window?.contentView?.superview, let path = query["path"],
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        default:
            break
        }
    }
}
