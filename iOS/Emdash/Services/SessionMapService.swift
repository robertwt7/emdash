import Foundation
import CryptoKit

/// Manages Claude session isolation with deterministic UUIDs and persistent session map.
/// Port of Electron's applySessionIsolation() + session map from ptyManager.ts.
final class SessionMapService {
    private var sessionMap: [String: SessionEntry]?
    private let fileManager = FileManager.default

    struct SessionEntry: Codable {
        let uuid: String
        let cwd: String
    }

    // MARK: - Deterministic UUID

    /// Generate a deterministic UUID from input string (task/conversation ID).
    /// Matches Electron's deterministicUuid() — SHA-256 hash with RFC 4122 v4 version and variant bits.
    static func deterministicUuid(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        var bytes = Array(digest)

        // RFC 4122 version 4
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        // RFC 4122 variant
        bytes[8] = (bytes[8] & 0x3f) | 0x80

        let hex = bytes.prefix(16).map { String(format: "%02x", $0) }.joined()
        return [
            String(hex.prefix(8)),
            String(hex.dropFirst(8).prefix(4)),
            String(hex.dropFirst(12).prefix(4)),
            String(hex.dropFirst(16).prefix(4)),
            String(hex.dropFirst(20).prefix(12)),
        ].joined(separator: "-")
    }

    // MARK: - Persistence

    private var sessionMapUrl: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let emdashDir = appSupport.appendingPathComponent("emdash", isDirectory: true)
        try? fileManager.createDirectory(at: emdashDir, withIntermediateDirectories: true)
        return emdashDir.appendingPathComponent("pty-session-map.json")
    }

    private func loadSessionMap() -> [String: SessionEntry] {
        if let cached = sessionMap { return cached }

        guard let data = try? Data(contentsOf: sessionMapUrl),
              let map = try? JSONDecoder().decode([String: SessionEntry].self, from: data)
        else {
            sessionMap = [:]
            return [:]
        }
        sessionMap = map
        return map
    }

    private func saveSessionMap() {
        guard let map = sessionMap else { return }
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: sessionMapUrl, options: .atomic)
    }

    // MARK: - Session Lookup

    func getKnownSessionId(_ ptyId: String) -> String? {
        loadSessionMap()[ptyId]?.uuid
    }

    func markSessionCreated(ptyId: String, uuid: String, cwd: String) {
        var map = loadSessionMap()
        map[ptyId] = SessionEntry(uuid: uuid, cwd: cwd)
        sessionMap = map
        saveSessionMap()
        Log.pty.debug("Session created: \(ptyId) -> \(uuid)")
    }

    func removeSession(_ ptyId: String) {
        var map = loadSessionMap()
        map.removeValue(forKey: ptyId)
        sessionMap = map
        saveSessionMap()
    }

    /// Check if other sessions exist for the same provider in the same cwd.
    func hasOtherSameProviderSessions(
        ptyId: String,
        providerId: ProviderId,
        cwd: String
    ) -> Bool {
        let map = loadSessionMap()
        let prefix = providerId.rawValue + "-"
        return map.contains { key, entry in
            key != ptyId && key.hasPrefix(prefix) && entry.cwd == cwd
        }
    }

    // MARK: - Session Isolation Decision Tree

    /// Apply session isolation for providers with sessionIdFlag (currently Claude only).
    /// Returns extra CLI args to append, or nil if generic resume should be used instead.
    ///
    /// Decision tree matches Electron's applySessionIsolation() exactly:
    /// 1. Already seen this PTY → resume with known UUID
    /// 2. Additional chat tab → assign new deterministic UUID
    /// 3. Main chat with other sessions in same cwd → assign UUID
    /// 4. First-time main chat → proactively assign UUID
    /// 5. Resuming with no isolation → return nil (caller uses generic -c -r)
    func applySessionIsolation(
        provider: ProviderDefinition,
        ptyId: String,
        cwd: String,
        isResume: Bool
    ) -> [String]? {
        guard let sessionIdFlag = provider.sessionIdFlag else { return nil }
        guard let parsed = PtyIdHelper.parse(ptyId) else { return nil }

        let sessionUuid = Self.deterministicUuid(parsed.suffix)
        let isAdditionalChat = parsed.kind == .chat

        // Case 1: Already seen this PTY — resume
        if let known = getKnownSessionId(ptyId) {
            return ["--resume", known]
        }

        // Case 2: Additional chat tab — assign new UUID
        if isAdditionalChat {
            markSessionCreated(ptyId: ptyId, uuid: sessionUuid, cwd: cwd)
            return [sessionIdFlag, sessionUuid]
        }

        // Case 3: Main chat with other provider sessions in same cwd
        if hasOtherSameProviderSessions(ptyId: ptyId, providerId: parsed.providerId, cwd: cwd) {
            markSessionCreated(ptyId: ptyId, uuid: sessionUuid, cwd: cwd)
            return [sessionIdFlag, sessionUuid]
        }

        // Case 4: First-time main chat — proactively assign UUID for future resume
        if !isResume {
            markSessionCreated(ptyId: ptyId, uuid: sessionUuid, cwd: cwd)
            return [sessionIdFlag, sessionUuid]
        }

        // Case 5: Resuming single-chat with no isolation — caller uses generic resume flags
        return nil
    }
}
