import AppKit

/// Watches for a double-press shortcut (⌃X X, ⌘C C…) and for Esc in any app.
/// Uses a listen-only event tap, which needs the "Input Monitoring" permission. The first press still reaches the
/// frontmost app.
final class HotkeyMonitor {
    var onTrigger: (() -> Void)?
    /// The double-press shortcut to watch for; nil when the shortcut is a single press (handled by CarbonHotkey).
    var doubleTap: Hotkey?
    /// While the user records a new shortcut, presses shouldn't trigger anything.
    var paused = false
    var onEscape: (() -> Void)?
    private var tap: CFMachPort?
    private var lastPress: TimeInterval = 0
    private var retryTimer: Timer?
    private static let interval: TimeInterval = 0.4
    private static let keyEscape: Int64 = 53

    static var hasPermission: Bool { CGPreflightListenEventAccess() }
    static func requestPermission() { CGRequestListenEventAccess() }

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    /// Keeps retrying until the user grants Input Monitoring, then starts.
    func startWhenPermitted() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            if self?.start() == true {
                timer.invalidate()
                Task { @MainActor in DebugLog.write("event tap started after permission was granted") }
            }
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .keyDown else { return }
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == Self.keyEscape, flags.isEmpty {
            DispatchQueue.main.async { self.onEscape?() }
            return
        }
        guard !paused, let hotkey = doubleTap, flags == hotkey.cgFlags, keyCode == Int64(hotkey.keyCode),
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
            lastPress = 0
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPress < Self.interval {
            lastPress = 0
            DispatchQueue.main.async { self.onTrigger?() }
        } else {
            lastPress = now
            OpenAIClient.warmUp()
        }
    }
}

/// Reads the selected text in the frontmost app through the Accessibility API, without touching the clipboard.
enum Selection {
    struct Result {
        let text: String
        /// True when the selection is inside an editable text field (most likely the user's own draft).
        let editable: Bool
        /// The text field, kept so a result can replace the selection later.
        let element: AXUIElement?
        /// The app the selection is in.
        var pid: pid_t = 0
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    /// Why the last `current()` found nothing (or how it found something), for the event log. Never the text.
    nonisolated(unsafe) private(set) static var lastReport = ""
    /// False when the app the last `read` looked at tells assistive apps nothing about selections at all (so
    /// "nothing found" doesn't mean "nothing selected", and asking the app to copy is worth a try).
    nonisolated(unsafe) private(set) static var lastWasConclusive = true
    /// The focused element's role in the last `read` (a password field is never copied from).
    nonisolated(unsafe) private(set) static var lastFocusedRole = ""

    static func current() -> Result? {
        lastWasConclusive = true
        lastFocusedRole = ""
        guard isTrusted else { lastReport = "no accessibility permission"; return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { lastReport = "no frontmost app"; return nil }
        let name = app.bundleIdentifier ?? "?"
        // Sayso's own windows are never a source: the shortcut there just shows or hides the panel.
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { lastReport = "app=Sayso"; return nil }
        return read(pid: app.processIdentifier, name: name)
    }

    /// The selection in one app (the frontmost one in normal use).
    static func read(pid: pid_t, name: String) -> Result? {
        let appElement = AXUIElementCreateApplication(pid)
        // A busy app must not stall the shortcut.
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        lastWasConclusive = false
        lastFocusedRole = ""
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
        guard status == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            lastReport = "app=\(name) focused=error \(status.rawValue)"
            return nil
        }
        let start = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(start, 0.5)
        lastFocusedRole = role(of: start)
        // The focused element first; in a web page the selection belongs to the page around it, so look upward too.
        var element = start
        var trail: [String] = []
        for depth in 0..<8 {
            trail.append(role(of: element))
            let (text, supported) = selection(of: element)
            if supported { lastWasConclusive = true }
            if let text {
                let editable = isEditable(start)
                lastReport = "app=\(name) found at depth \(depth) roles=\(trail.joined(separator: ">"))"
                return Result(text: text, editable: editable, element: editable && depth == 0 ? start : nil, pid: pid)
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
            if role(of: element) == (kAXApplicationRole as String) { break }
        }
        lastReport = "app=\(name) \(lastWasConclusive ? "nothing selected" : "selection not exposed") in roles=\(trail.joined(separator: ">"))"
        return nil
    }

    private static func role(of element: AXUIElement) -> String {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return role as? String ?? "?"
    }

    /// The element's selected text: the plain attribute most apps offer, or the text-marker range web pages use
    /// (Safari, Chrome, Electron apps).
    static func selectedText(of element: AXUIElement) -> String? { selection(of: element).text }

    /// The selected text, and whether the element answers questions about selections at all.
    private static func selection(of element: AXUIElement) -> (text: String?, supported: Bool) {
        func clean(_ value: CFTypeRef?) -> String? {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        var supported = false
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success {
            supported = true
            if let text = clean(value) { return (text, true) }
        }
        var range: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &range) == .success, let range {
            supported = true
            var string: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString, range, &string) == .success,
               let text = clean(string) { return (text, true) }
        }
        return (nil, supported)
    }

    /// Puts `replacement` in place of the selection, if that field still has `original` selected.
    static func replace(in element: AXUIElement, original: String, with replacement: String) -> Bool {
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let current = selected as? String,
              current.trimmingCharacters(in: .whitespacesAndNewlines) == original.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, replacement as CFString) == .success
        else { return false }
        // Some apps report success without changing anything; check.
        var after: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &after)
        return (after as? String) != current || current == replacement
    }

    /// Debug: the selection of the first web page found in an app's windows, wherever the keyboard focus is
    /// (a test window that never becomes active has no focused element to start from).
    static func readWebArea(pid: pid_t) -> String? {
        var queue = [AXUIElementCreateApplication(pid)]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let element = queue.removeFirst()
            visited += 1
            if role(of: element) == "AXWebArea" { return selectedText(of: element) }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] { queue.append(contentsOf: list) }
        }
        return nil
    }

    /// Debug: for each running app, what its focused element and the elements around it offer (codes and lengths,
    /// never text).
    static func probe() -> [[String: Any]] {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map { app in
            var row: [String: Any] = ["app": app.localizedName ?? "?", "bundle": app.bundleIdentifier ?? "?",
                                      "frontmost": app.processIdentifier == front]
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.5)
            var focused: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
            row["focusedStatus"] = status.rawValue
            guard status == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return row }
            var element = focused as! AXUIElement
            row["editable"] = isEditable(element)
            var chain: [String] = []
            for _ in 0..<8 {
                var selected: CFTypeRef?
                let plain = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected)
                var range: CFTypeRef?
                let marker = AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &range)
                var length = -1
                if let range {
                    var string: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString, range, &string) == .success {
                        length = (string as? String)?.count ?? -1
                    }
                }
                chain.append("\(role(of: element)) plain=\(plain.rawValue)/\((selected as? String)?.count ?? -1) marker=\(marker.rawValue)/\(length)")
                var parent: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                      let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                element = parent as! AXUIElement
                if role(of: element) == (kAXApplicationRole as String) { break }
            }
            row["chain"] = chain
            return row
        }
    }

    /// A text field or text area whose contents can be changed. Read-only text views (a chat transcript, a
    /// terminal) and controls whose value merely happens to be settable (checkboxes, sliders) don't count.
    private static func isEditable(_ element: AXUIElement) -> Bool {
        guard [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(where: { ($0 as String) == role(of: element) })
        else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success else { return true }
        return settable.boolValue
    }
}
