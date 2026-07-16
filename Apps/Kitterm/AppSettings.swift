import AppKit
import Combine
import Foundation
import SwiftTerm

enum TerminalTheme: String, CaseIterable, Identifiable, Sendable {
    case dark
    case light
    case oneDark
    case solarizedDark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .oneDark: return "One Dark"
        case .solarizedDark: return "Solarized Dark"
        }
    }

    var foreground: NSColor {
        switch self {
        case .dark:
            return NSColor(calibratedRed: 0.86, green: 0.86, blue: 0.86, alpha: 1)
        case .light:
            return NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.15, alpha: 1)
        case .oneDark:
            return NSColor(calibratedRed: 0.67, green: 0.70, blue: 0.75, alpha: 1)
        case .solarizedDark:
            return NSColor(calibratedRed: 0.51, green: 0.58, blue: 0.59, alpha: 1)
        }
    }

    var background: NSColor {
        switch self {
        case .dark:
            return NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1)
        case .light:
            return NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.97, alpha: 1)
        case .oneDark:
            return NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.21, alpha: 1)
        case .solarizedDark:
            return NSColor(calibratedRed: 0.00, green: 0.17, blue: 0.21, alpha: 1)
        }
    }

    var caret: NSColor {
        switch self {
        case .light:
            return NSColor.systemBlue
        case .dark, .oneDark, .solarizedDark:
            return NSColor.systemGreen
        }
    }
}

enum CursorStyleSetting: String, CaseIterable, Identifiable, Sendable {
    case blinkBlock
    case steadyBlock
    case blinkUnderline
    case steadyUnderline
    case blinkBar
    case steadyBar

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blinkBlock: return "Blinking Block"
        case .steadyBlock: return "Steady Block"
        case .blinkUnderline: return "Blinking Underline"
        case .steadyUnderline: return "Steady Underline"
        case .blinkBar: return "Blinking Bar"
        case .steadyBar: return "Steady Bar"
        }
    }

    var swiftTermStyle: CursorStyle {
        switch self {
        case .blinkBlock: return .blinkBlock
        case .steadyBlock: return .steadyBlock
        case .blinkUnderline: return .blinkUnderline
        case .steadyUnderline: return .steadyUnderline
        case .blinkBar: return .blinkBar
        case .steadyBar: return .steadyBar
        }
    }
}

/// UserDefaults-backed terminal appearance settings.
@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let fontName = "kitterm.fontName"
        static let fontSize = "kitterm.fontSize"
        static let theme = "kitterm.theme"
        static let cursorStyle = "kitterm.cursorStyle"
        static let scrollback = "kitterm.scrollback"
    }

    @Published var fontName: String {
        didSet { UserDefaults.standard.set(fontName, forKey: Keys.fontName) }
    }

    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize) }
    }

    @Published var theme: TerminalTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme) }
    }

    @Published var cursorStyle: CursorStyleSetting {
        didSet { UserDefaults.standard.set(cursorStyle.rawValue, forKey: Keys.cursorStyle) }
    }

    @Published var scrollback: Int {
        didSet { UserDefaults.standard.set(scrollback, forKey: Keys.scrollback) }
    }

    init() {
        let defaults = UserDefaults.standard
        fontName = defaults.string(forKey: Keys.fontName) ?? "Menlo"
        let size = defaults.double(forKey: Keys.fontSize)
        fontSize = size > 0 ? size : 13
        if let raw = defaults.string(forKey: Keys.theme),
           let value = TerminalTheme(rawValue: raw) {
            theme = value
        } else {
            theme = .dark
        }
        if let raw = defaults.string(forKey: Keys.cursorStyle),
           let value = CursorStyleSetting(rawValue: raw) {
            cursorStyle = value
        } else {
            cursorStyle = .blinkBlock
        }
        let lines = defaults.integer(forKey: Keys.scrollback)
        scrollback = lines > 0 ? lines : 10_000
    }

    var resolvedFont: NSFont {
        if let named = NSFont(name: fontName, size: CGFloat(fontSize)) {
            return named
        }
        return NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
    }

    static let availableFonts: [String] = {
        let monospace = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let preferred = ["Menlo", "SF Mono", "Andale Mono", "Courier New", "Monaco"]
        var seen = Set<String>()
        var ordered: [String] = []
        for name in preferred + monospace.sorted() {
            if seen.insert(name).inserted {
                ordered.append(name)
            }
        }
        return ordered
    }()
}
