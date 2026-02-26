import Foundation

/// Shell escaping utilities matching the Electron app's shellEscape.ts
enum ShellEscape {
    /// Single-quote wraps a string for safe shell argument passing.
    /// Matches the POSIX idiom: end quote, escaped quote, reopen quote.
    static func quoteShellArg(_ arg: String) -> String {
        "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Validates a POSIX-compliant environment variable name.
    /// Must start with letter or underscore, followed by letters/digits/underscores.
    static func isValidEnvVarName(_ name: String) -> Bool {
        let pattern = "^[A-Za-z_][A-Za-z0-9_]*$"
        return name.range(of: pattern, options: .regularExpression) != nil
    }
}
