import AppKit
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: SayModel
    let onHeight: (CGFloat, Bool) -> Void
    /// The content's own height, without the filler below it.
    @State private var naturalHeight: CGFloat = 0

    var body: some View {
        GeometryReader { viewport in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    content
                    // While answers stream in the window only grows, so the content can end up shorter than the
                    // window for a moment. That space continues the two columns instead of showing blank white.
                    if model.hasResults, model.notice == nil, viewport.size.height - naturalHeight > 0.5 {
                        HStack(spacing: 0) {
                            Color(nsColor: Theme.sharpWash)
                            Rectangle().fill(Color.hairline).frame(width: 1)
                            Color(nsColor: Theme.chillWash)
                        }
                        .frame(height: viewport.size.height - naturalHeight)
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
        .background(Color.paper)
        .ignoresSafeArea()
        .onChange(of: model.isRunning) { _, running in
            if !running { DispatchQueue.main.async { model.onLayoutChange?(true) } }
        }
    }

    private var content: some View {
            VStack(spacing: 0) {
                ModeSwitch(selection: model.mode) { model.pick($0) }
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .trailing) { HeaderButtons(model: model).padding(.trailing, 12) }
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                InputSection(model: model)
                if model.hasResults || model.notice != nil {
                    Rectangle().fill(Color.hairline).frame(height: 1)
                        .overlay { if model.canUpdate { UpdatePill { model.run() } } }
                        .zIndex(1)
                    if let notice = model.notice {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.inkTertiary)
                            Text(notice)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            if model.noticeOpensSettings {
                                Button("Open Settings") { AppDelegate.shared.showSettings() }
                                    .controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    } else {
                        HStack(alignment: .top, spacing: 0) {
                            VoiceColumn(model: model, voice: .sharp, output: model.outputs[.sharp] ?? VoiceOutput())
                                .frame(maxHeight: .infinity, alignment: .top)
                                .background(Color(nsColor: Theme.sharpWash))
                            Rectangle().fill(Color.hairline).frame(width: 1)
                            VoiceColumn(model: model, voice: .chill, output: model.outputs[.chill] ?? VoiceOutput())
                                .frame(maxHeight: .infinity, alignment: .top)
                                .background(Color(nsColor: Theme.chillWash))
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .animation(.easeOut(duration: 0.18), value: model.isStale)
            .animation(.easeOut(duration: 0.18), value: model.canUpdate)
            .background(GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                    naturalHeight = ceil(height)
                    onHeight(ceil(height), !model.isRunning)
                }
            })
    }
}

/// Pin, history and settings, quiet until hovered.
private struct HeaderButtons: View {
    @ObservedObject var model: SayModel

    var body: some View {
        HStack(spacing: 2) {
            IconButton(symbol: model.pinned ? "pin.fill" : "pin", active: model.pinned, help: "Keep on top") {
                model.pinned.toggle()
            }
            IconButton(symbol: "clock.arrow.circlepath", help: "History (⌘Y)") { AppDelegate.shared.showHistory() }
            IconButton(symbol: "gearshape", help: "Settings (⌘,)") { AppDelegate.shared.showSettings() }
        }
    }
}

private struct IconButton: View {
    let symbol: String
    var active = false
    var help = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 24, height: 24)
                .foregroundStyle(active ? Color(nsColor: Theme.sharp) : (hover ? Color.ink : Color.inkTertiary))
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.well : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

/// Polish / Reply / 中 → En, like the Chat / Code switch in the Claude app.
private struct ModeSwitch: View {
    let selection: Mode
    let pick: (Mode) -> Void
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Mode.allCases, id: \.self) { mode in
                let on = mode == selection
                Text(mode.title)
                    .font(.system(size: 12, weight: on ? .medium : .regular))
                    .foregroundStyle(on ? Color.ink : Color.inkSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.paper)
                                .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy(duration: 0.22)) { pick(mode) } }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.well))
    }
}

private struct InputSection: View {
    @ObservedObject var model: SayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InputTextView(model: model, placeholder: model.mode.placeholder)
                .frame(height: model.inputHeight)
            if model.mode == .reply {
                NoteField(model: model)
                    .padding(.top, 10)
                    .padding(.horizontal, 5)
            }
            if model.mode == .polish, !model.issues.isEmpty || (model.isRunning && model.marksAreCurrent) {
                fixes
                    .opacity(model.marksAreCurrent ? 1 : 0.38)
                    .frame(maxWidth: .infinity, minHeight: 18, alignment: .topLeading)
                    .padding(.top, 8)
                    .padding(.horizontal, 5)
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    private var fixes: Text {
        model.issues.enumerated().reduce(Text("")) { line, item in
            let (index, issue) = item
            return line
                + Text(index == 0 ? "" : "     ")
                + Text(issue.wrong).strikethrough().foregroundColor(.inkTertiary)
                + Text("  →  ").foregroundColor(.inkTertiary)
                + Text(issue.fix).foregroundColor(Color(nsColor: Theme.fixed))
        }
        .font(.system(size: 13))
    }
}

/// Reply mode: an optional line saying what the user wants to answer, in English or Chinese. Enter regenerates.
private struct NoteField: View {
    @ObservedObject var model: SayModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.inkTertiary)
            TextField("How do you want to reply? (optional)", text: $model.note, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Color.inkSecondary)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit { model.run() }
                .onKeyPress(.tab) { model.focusText(); return .handled }
                .onExitCommand { AppDelegate.shared.panel.hide() }
        }
        .onChange(of: model.focusNoteRequest) { _, _ in takeFocus() }
        .onAppear(perform: takeFocus)
    }

    /// Only when the model asked for it: a note field that merely appears (switching to Reply with nothing
    /// typed yet) leaves the keyboard in the main text.
    private func takeFocus() {
        guard model.noteFocusPending else { return }
        model.noteFocusPending = false
        focused = true
    }
}

private struct VoiceColumn: View {
    @ObservedObject var model: SayModel
    let voice: Voice
    let output: VoiceOutput
    @State private var hovering = false
    @State private var copied = false

    private var tint: NSColor { voice == .sharp ? Theme.sharp : Theme.chill }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: voice == .sharp ? "sparkle" : "leaf")
                        .font(.system(size: 9, weight: .semibold))
                    Text(voice.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.7)
                }
                .foregroundStyle(Color(nsColor: tint))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color(nsColor: voice == .sharp ? Theme.sharpHighlight : Theme.chillHighlight)))
                if output.streaming { PulseDot(color: Color(nsColor: tint)) }
                Spacer(minLength: 0)
                if !output.streaming, !output.body.isEmpty {
                    HStack(spacing: 0) {
                        IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy") { copy() }
                        if model.canReplace, output.error == nil {
                            IconButton(symbol: "arrow.uturn.backward", help: "Replace the original text") {
                                model.replaceOriginal(with: output.body, willPaste: { AppDelegate.shared.panel.hide() }) { replaced in
                                    if replaced {
                                        AppDelegate.shared.panel.hide()
                                    } else {
                                        // Couldn't put it back: the text is on the clipboard instead.
                                        AppDelegate.shared.panel.show(text: nil, editable: nil)
                                        copy()
                                    }
                                }
                            }
                        }
                    }
                    .opacity(hovering || copied || UserDefaults.standard.bool(forKey: "debugShowActions") ? 1 : 0)
                    .frame(height: 20)
                    .padding(.trailing, -8)
                }
            }
            .frame(height: 22)
            if let ghost = model.ghosts[voice], output.raw.isEmpty {
                Text(ghost)
                    .font(.system(size: Theme.textSize))
                    .lineSpacing(3)
                    .foregroundStyle(Color.ink)
                    .opacity(0.38)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !output.body.isEmpty || output.error == nil {
                Text(highlighted)
                    .font(.system(size: Theme.textSize))
                    .lineSpacing(3)
                    .foregroundStyle(Color.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(model.isStale ? 0.38 : 1)
            }
            if let error = output.error {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output.body, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    /// The text with each phrase to learn tinted in the voice's colour (only once the list has arrived).
    private var highlighted: AttributedString {
        let text = output.body
        var attributed = AttributedString(text)
        let folded = Array(VoiceOutput.fold(text))
        let background = Color(nsColor: voice == .sharp ? Theme.sharpHighlight : Theme.chillHighlight)
        for phrase in output.highlights {
            let needle = Array(VoiceOutput.fold(phrase))
            guard !needle.isEmpty, needle.count <= folded.count,
                  let start = (0...(folded.count - needle.count)).first(where: { Array(folded[$0..<$0 + needle.count]) == needle })
            else { continue }
            let lower = attributed.characters.index(attributed.startIndex, offsetBy: start)
            let upper = attributed.characters.index(lower, offsetBy: needle.count)
            attributed[lower..<upper].backgroundColor = background
        }
        return attributed
    }
}

/// Shown on the divider once the text has been edited: the answers below are for the old text.
private struct UpdatePill: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "return").font(.system(size: 10, weight: .semibold))
                Text("Update").font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(Color(nsColor: Theme.sharp))
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(hover ? Color(nsColor: Theme.sharpWash) : Color.paper))
            .overlay(Capsule().strokeBorder(Color(nsColor: Theme.sharp).opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Answer the edited text (↩)")
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

private struct PulseDot: View {
    let color: Color
    @State private var on = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .opacity(on ? 0.9 : 0.2)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

// MARK: - Input

final class InputNSTextView: NSTextView {
    var placeholder = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }
    var onWidthChange: (() -> Void)?
    /// The modifiers of the key press being handled (⇧↩ is a line break, ↩ sends).
    private(set) var keyFlags: NSEvent.ModifierFlags?

    override func keyDown(with event: NSEvent) {
        keyFlags = event.modifierFlags
        super.keyDown(with: event)
        keyFlags = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: [.font: Theme.textFont, .foregroundColor: Theme.tertiaryText])
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changed { onWidthChange?() }
    }
}

struct InputTextView: NSViewRepresentable {
    let model: SayModel
    let placeholder: String

    func makeNSView(context: Context) -> InputNSTextView {
        let textView = InputNSTextView(usingTextLayoutManager: false)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = Theme.textFont
        textView.textColor = Theme.text
        textView.typingAttributes = Theme.textAttributes
        textView.defaultParagraphStyle = Theme.paragraph()
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 5
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.insertionPointColor = Theme.sharp
        textView.selectedTextAttributes = [.backgroundColor: Theme.selection]
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = model
        textView.placeholder = placeholder
        textView.onWidthChange = { [weak model] in DispatchQueue.main.async { model?.measureInput() } }
        model.register(textView)
        return textView
    }

    func updateNSView(_ nsView: InputNSTextView, context: Context) {
        nsView.placeholder = placeholder
    }
}

extension VoiceOutput {
    /// Lower-cased with curly quotes made straight, one character for one, so ranges line up with the original.
    static func fold(_ text: String) -> [Character] {
        text.map { character -> Character in
            switch character {
            case "’", "‘": "'"
            case "“", "”": "\""
            default: Character(character.lowercased().count == 1 ? character.lowercased() : String(character))
            }
        }
    }
}
