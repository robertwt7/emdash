import Foundation
import os

/// Centralized logger using Apple's unified logging system.
enum Log {
    private static let subsystem = "com.emdash.ios"

    static let general = os.Logger(subsystem: subsystem, category: "general")
    static let ssh = os.Logger(subsystem: subsystem, category: "ssh")
    static let pty = os.Logger(subsystem: subsystem, category: "pty")
    static let git = os.Logger(subsystem: subsystem, category: "git")
    static let agent = os.Logger(subsystem: subsystem, category: "agent")
    static let db = os.Logger(subsystem: subsystem, category: "database")
}
