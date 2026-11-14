// A small window to check how Sayso reads and replaces selections. It never becomes the active app, and its
// text views copy to and paste from a pasteboard of their own (SAYSO_TEST_PASTEBOARD), never the real clipboard.
//   web page · native text view · read-only text view · two text views hidden from accessibility ("opaque"),
//   which Sayso can only reach through this app's Edit ▸ Copy / Paste commands.
// Commands arrive as lines on stdin (see run()).
import AppKit
import CryptoKit
import WebKit

let board = NSPasteboard(name: NSPasteboard.Name(ProcessInfo.processInfo.environment["SAYSO_TEST_PASTEBOARD"] ?? "sayso.test"))

class TestTextView: NSTextView {
    override func copy(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        board.clearContents()
        board.setString((string as NSString).substring(with: selectedRange()), forType: .string)
    }
    override func paste(_ sender: Any?) {
        guard isEditable, let text = board.string(forType: .string) else { return }
        insertText(text, replacementRange: selectedRange())
    }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRange().length > 0 }
        if item.action == #selector(paste(_:)) { return isEditable && board.string(forType: .string) != nil }
        return super.validateUserInterfaceItem(item)
    }
}

/// Says nothing to assistive apps, like the custom text areas of some apps.
final class OpaqueTextView: TestTextView {
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .unknown }
    override func accessibilitySelectedText() -> String? { nil }
}

final class Host: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let view = focusedText else { return false }
        if item.action == #selector(hostCopy(_:)) { return view.selectedRange().length > 0 }
        return view.isEditable && board.string(forType: .string) != nil
    }

    var window: NSWindow!
    var web: WKWebView!
    var native: TestTextView!
    var readonly: TestTextView!
    var opaque: OpaqueTextView!
    var opaqueReadonly: OpaqueTextView!

    func applicationDidFinishLaunching(_ note: Notification) {
        let main = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = NSMenu(title: "Host"); main.addItem(appItem)
        let fileItem = NSMenuItem(); fileItem.submenu = NSMenu(title: "File"); main.addItem(fileItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit")
        // In an active app these commands go to the focused view by themselves. This window never becomes active,
        // so the commands are sent to its focused view by hand.
        for (title, action, key) in [("Copy", #selector(hostCopy(_:)), "c"), ("Paste", #selector(hostPaste(_:)), "v")] {
            let item = edit.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
        }
        editItem.submenu = edit; main.addItem(editItem)
        NSApp.mainMenu = main

        window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 420, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Sayso selection test"
        web = WKWebView(frame: NSRect(x: 0, y: 260, width: 420, height: 120))
        web.loadHTMLString("<p id=t>Hello from the test page, this text is selected.</p><textarea id=a rows=2 cols=40>I has a apple</textarea><div id=c contenteditable>Me and him goes there</div>", baseURL: nil)
        func make<T: NSTextView>(_ type: T.Type, y: CGFloat, _ text: String, editable: Bool = true) -> T {
            let view = T(frame: NSRect(x: 0, y: y, width: 420, height: 60))
            view.string = text
            view.isEditable = editable
            return view
        }
        native = make(TestTextView.self, y: 195, "She don't like it")
        readonly = make(TestTextView.self, y: 130, "Are you free on Friday?", editable: false)
        opaque = make(OpaqueTextView.self, y: 65, "I very like this idea")
        opaqueReadonly = make(OpaqueTextView.self, y: 0, "See you at the meeting tomorrow.", editable: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 380))
        [web, native, readonly, opaque, opaqueReadonly].forEach { content.addSubview($0!) }
        window.contentView = content
        window.orderFrontRegardless()
        window.makeKey()
        print("pid \(ProcessInfo.processInfo.processIdentifier)"); fflush(stdout)
        DispatchQueue.global().async {
            while let line = readLine() { DispatchQueue.main.async { self.run(line) } }
        }
    }

    private var focusedText: TestTextView? { window.firstResponder as? TestTextView }
    @objc func hostCopy(_ sender: Any?) { focusedText?.copy(sender) }
    @objc func hostPaste(_ sender: Any?) { focusedText?.paste(sender) }

    func say(_ text: String) { print(text); fflush(stdout) }

    func js(_ code: String, _ label: String) {
        window.makeFirstResponder(web)
        web.evaluateJavaScript(code) { value, error in self.say("\(label): \(value ?? "nil") \(error.map { "\($0)" } ?? "")") }
    }

    /// A fingerprint of everything on the test pasteboard: every item, every format, every byte.
    func digest() -> String {
        var hasher = SHA256()
        var summary: [String] = []
        for item in board.pasteboardItems ?? [] {
            for type in item.types {
                let data = item.data(forType: type) ?? Data()
                hasher.update(data: Data(type.rawValue.utf8)); hasher.update(data: data)
                summary.append("\(type.rawValue)(\(data.count))")
            }
            summary.append("|")
        }
        return hasher.finalize().prefix(6).map { String(format: "%02x", $0) }.joined() + " " + summary.joined(separator: " ")
    }

    func select(_ view: NSTextView, all: Bool = true) {
        window.makeFirstResponder(view)
        view.setSelectedRange(all ? NSRange(location: 0, length: (view.string as NSString).length) : NSRange(location: 0, length: 0))
    }

    func run(_ command: String) {
        switch command {
        case "page": js("getSelection().selectAllChildren(document.getElementById('t')); getSelection().toString().length", "page")
        case "textarea": js("var a=document.getElementById('a'); a.focus(); a.select(); a.value.length", "textarea")
        case "editable": js("var c=document.getElementById('c'); c.focus(); getSelection().selectAllChildren(c); getSelection().toString().length", "editable")
        case "value": js("document.getElementById('a').value + ' | ' + document.getElementById('c').textContent", "value")
        case "native": select(native); say("native: \(native.string.count)")
        case "nativevalue": say("nativevalue: \(native.string)")
        case "readonly": select(readonly); say("readonly: \(readonly.string.count)")
        case "opaque": select(opaque); say("opaque: \(opaque.string.count)")
        case "opaquenone": select(opaque, all: false); say("opaquenone")
        case "opaquereadonly": select(opaqueReadonly); say("opaquereadonly: \(opaqueReadonly.string.count)")
        case "opaquevalue": say("opaquevalue: \(opaque.string)")
        case "seed":
            // Two items, several formats, like a real clipboard after copying rich content.
            board.clearContents()
            let first = NSPasteboardItem()
            first.setString("what the user copied earlier", forType: .string)
            first.setData(Data("{\\rtf1 what the user copied earlier}".utf8), forType: .rtf)
            first.setData(Data((0..<5000).map { UInt8($0 % 251) }), forType: .png)
            let second = NSPasteboardItem()
            second.setString("a second item", forType: .string)
            board.writeObjects([first, second])
            say("seed: \(digest())")
        case "secret":
            board.clearContents()
            let item = NSPasteboardItem()
            item.setString("hunter2", forType: .string)
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            board.writeObjects([item])
            say("secret: \(digest())")
        case "digest": say("digest: \(digest())")
        case "quit": exit(0)
        default: break
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let host = Host()
app.delegate = host
app.run()
