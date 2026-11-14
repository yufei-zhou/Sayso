import AppKit
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// Clean white palette: paper-white panel, cool ink, one hue per voice.
@MainActor
enum Theme {
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    static let background = dynamic(NSColor(hex: 0xFFFFFF), NSColor(hex: 0x1C1C1F))
    static let well = dynamic(NSColor(hex: 0xF4F4F6), NSColor(hex: 0x26262A))
    static let text = dynamic(NSColor(hex: 0x16161A), NSColor(hex: 0xEDEDF2))
    static let secondaryText = dynamic(NSColor(hex: 0x6B6B76), NSColor(hex: 0xA3A3AE))
    static let tertiaryText = dynamic(NSColor(hex: 0xA9A9B3), NSColor(hex: 0x6C6C78))
    static let border = dynamic(NSColor(hex: 0xE8E8EC), NSColor(hex: 0x323238))
    static let error = NSColor(hex: 0xE24B4A)
    static let fixed = dynamic(NSColor(hex: 0x16824F), NSColor(hex: 0x4FD18A))

    static let sharp = dynamic(NSColor(hex: 0x534AB7), NSColor(hex: 0xA49CF0))
    static let chill = dynamic(NSColor(hex: 0x12876A), NSColor(hex: 0x4FD1A8))
    static let sharpHighlight = dynamic(NSColor(hex: 0x534AB7, alpha: 0.14), NSColor(hex: 0xA49CF0, alpha: 0.24))
    static let chillHighlight = dynamic(NSColor(hex: 0x1D9E75, alpha: 0.16), NSColor(hex: 0x4FD1A8, alpha: 0.22))
    /// Faint background tint behind each voice's column.
    static let sharpWash = dynamic(NSColor(hex: 0xF8F7FD), NSColor(hex: 0x201F29))
    static let chillWash = dynamic(NSColor(hex: 0xF4FAF7), NSColor(hex: 0x1B2422))
    static let selection = dynamic(NSColor(hex: 0x534AB7, alpha: 0.20), NSColor(hex: 0xA49CF0, alpha: 0.30))

    static let textSize: CGFloat = 16
    static var textFont: NSFont { NSFont.systemFont(ofSize: textSize) }

    static func paragraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.18
        p.paragraphSpacing = 6
        return p
    }

    static var textAttributes: [NSAttributedString.Key: Any] {
        [.font: textFont, .foregroundColor: text, .paragraphStyle: paragraph()]
    }
}

extension Color {
    @MainActor static let ink = Color(nsColor: Theme.text)
    @MainActor static let inkSecondary = Color(nsColor: Theme.secondaryText)
    @MainActor static let inkTertiary = Color(nsColor: Theme.tertiaryText)
    @MainActor static let hairline = Color(nsColor: Theme.border)
    @MainActor static let paper = Color(nsColor: Theme.background)
    @MainActor static let well = Color(nsColor: Theme.well)
}
