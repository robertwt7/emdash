import Foundation

/// Strips ANSI escape sequences from terminal output for plain-text rendering.
/// Handles CSI sequences (colors, cursor movement, erase), OSC sequences (title, hyperlinks),
/// and simple escape codes that TUI apps (Gemini, Amp, etc.) emit even with TERM=dumb.
enum ANSIStripper {
    // CSI: ESC [ <params> <intermediate> <final>
    // Covers colors, cursor movement, erase line/screen, scrolling, etc.
    // OSC: ESC ] <text> (BEL | ESC \)
    // Covers terminal title, hyperlinks, etc.
    // Simple: ESC <single char> (e.g., ESC M for reverse index)
    private static let ansiPattern: NSRegularExpression = {
        let pattern = [
            "\\x1B\\[[0-9;]*[ -/]*[A-Za-z]",  // CSI sequences (with optional intermediates)
            "\\x1B\\][^\\x07]*(?:\\x07|\\x1B\\\\)", // OSC sequences: ESC]...BEL or ESC]...ST
            "\\x1B[()][A-Z0-9]",               // Character set selection
            "\\x1B[A-Z@-_]",                   // Simple ESC sequences (e.g., ESC M)
        ].joined(separator: "|")
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Strip all ANSI escape sequences from a string.
    static func strip(_ input: String) -> String {
        guard input.contains("\u{1B}") else { return input }
        let range = NSRange(input.startIndex..., in: input)
        return ansiPattern.stringByReplacingMatches(in: input, range: range, withTemplate: "")
    }
}
