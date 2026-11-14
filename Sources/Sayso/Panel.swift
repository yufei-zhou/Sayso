import AppKit
import SwiftUI

final class SaysoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    var onCommand: ((String) -> Bool)?

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let key = event.charactersIgnoringModifiers, onCommand?(key) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Owns the floating panel: where it appears, how tall it is, and when it closes.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let model = SayModel()
    private lazy var panel: SaysoPanel = makePanel()
    private var placing = false
    private var outsideClickMonitor: Any?

    static let width: CGFloat = 600
    static let maxHeight: CGFloat = 640

    private func makePanel() -> SaysoPanel {
        let panel = SaysoPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 160),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = Theme.background
        panel.minSize = NSSize(width: 460, height: 100)
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        let host = NSHostingView(rootView: PanelView(model: model, onHeight: { [weak self] height, shrink in
            self?.fit(contentHeight: height, allowShrink: shrink)
        }))
        host.sizingOptions = []
        panel.contentView = host
        panel.onCommand = { [weak self] key in self?.command(key) ?? false }
        model.onLayoutChange = { [weak self] shrink in
            guard let self else { return }
            DispatchQueue.main.async { self.fit(contentHeight: self.lastContentHeight, allowShrink: shrink) }
        }
        return panel
    }

    private func command(_ key: String) -> Bool {
        switch key {
        case "w", "q": hide()
        case "n": model.clear(); model.focusInput()
        case "1": model.pick(.polish)
        case "2": model.pick(.reply)
        case "3": model.pick(.zh)
        case ",": AppDelegate.shared.showSettings()
        case "y": AppDelegate.shared.showHistory()
        case "r": model.run()
        default: return false
        }
        return true
    }

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isVisible && panel.isKeyWindow }
    var windowNumber: Int { panel.windowNumber }

    /// Shows the panel. With new text it starts right away; without, it reopens as it was left.
    func show(text: String?, editable: Bool?, element: AXUIElement? = nil, pid: pid_t = 0, takeFocus: Bool = true) {
        if let text {
            model.load(text: text, editable: editable, element: element, pid: pid)
        }
        if !panel.isVisible {
            placing = true
            panel.setFrame(initialFrame(), display: false)
            placing = false
        }
        if takeFocus {
            panel.makeKeyAndOrderFront(nil)
            watchOutsideClicks()
            model.focusInput()
        } else {
            panel.orderFrontRegardless()
        }
        if text != nil { model.runSelection() }
        OpenAIClient.warmUp()
        // The content may have been measured before the panel was on screen; size to it now that it is.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fit(contentHeight: self.lastContentHeight, allowShrink: true)
        }
    }

    func hide() {
        model.save()
        panel.orderOut(nil)
    }

    /// Keeps the top edge fixed and makes the window as tall as its content. While answers stream in it only grows,
    /// so nothing jumps; once they finish it may shrink.
    private var lastContentHeight: CGFloat = 0
    private func fit(contentHeight: CGFloat, allowShrink: Bool) {
        lastContentHeight = contentHeight
        guard panel.isVisible, !panel.inLiveResize else { return }
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let height = min(contentHeight, min(Self.maxHeight, visible.height * 0.85)).rounded()
        var frame = panel.frame
        let shrinkOK = allowShrink && !model.isRunning
        guard abs(height - frame.height) >= 1, shrinkOK || height > frame.height else { return }
        frame.origin.y += frame.height - height
        frame.size.height = height
        frame.origin.y = max(frame.origin.y, visible.minY + 8)
        placing = true
        panel.setFrame(frame, display: true, animate: false)
        placing = false
    }

    private func initialFrame() -> NSRect {
        let savedWidth = UserDefaults.standard.double(forKey: "panelWidth")
        let width = savedWidth > 0 ? CGFloat(savedWidth) : Self.width
        let height = max(lastContentHeight, 120)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        var visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: mouse.x - width / 2, y: mouse.y - height - 18)
        if let saved = UserDefaults.standard.array(forKey: "panelTopLeft") as? [Double], saved.count == 2 {
            let topLeft = NSPoint(x: saved[0], y: saved[1])
            if let home = NSScreen.screens.first(where: { NSMouseInRect(topLeft, $0.frame.insetBy(dx: -1, dy: -1), false) }) {
                visible = home.visibleFrame
                origin = NSPoint(x: topLeft.x, y: topLeft.y - height)
            }
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - height - 8)
        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }

    private func watchOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible, !self.model.pinned,
                      !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.hide()
            }
        }
    }

    /// Esc pressed while another app had the keyboard.
    func escapePressedElsewhere() {
        guard panel.isVisible, !panel.isKeyWindow, !model.pinned else { return }
        hide()
    }

    func windowDidResignKey(_ notification: Notification) {
        model.save()
        if model.pinned { return }
        if NSEvent.pressedMouseButtons != 0, panel.frame.contains(NSEvent.mouseLocation) { return }
        hide()
    }

    func windowDidMove(_ notification: Notification) {
        guard !placing, panel.isVisible else { return }
        UserDefaults.standard.set([Double(panel.frame.minX), Double(panel.frame.maxY)], forKey: "panelTopLeft")
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        UserDefaults.standard.set(Double(panel.frame.width), forKey: "panelWidth")
        UserDefaults.standard.set([Double(panel.frame.minX), Double(panel.frame.maxY)], forKey: "panelTopLeft")
    }

    /// Debug: sends ⌘<key> to the panel the way the keyboard would.
    func simulateCommand(_ key: String) -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                           windowNumber: panel.windowNumber, context: nil, characters: key,
                                           charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0) else { return false }
        return panel.performKeyEquivalent(with: event)
    }

    /// Debug: delivers a key press to whatever has the keyboard focus inside the panel (Esc, Return, Tab…),
    /// without the panel having to take the keyboard from the app the user is in.
    func simulateKeyDown(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                           windowNumber: panel.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
        panel.sendEvent(event)
    }

    /// Debug: which view has the keyboard focus inside the panel.
    var debugFocus: String {
        guard let responder = panel.firstResponder else { return "none" }
        if responder === model.textView { return "input" }
        if responder === panel { return "window" }
        return String(describing: type(of: responder))
    }

    /// Debug: what's on screen, for checks.
    var debugState: [String: Any] {
        ["visible": panel.isVisible, "frame": NSStringFromRect(panel.frame), "contentHeight": lastContentHeight,
         "focus": debugFocus]
    }

    /// Debug: renders the panel's content into a PNG.
    func snapshot(to url: URL) {
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
