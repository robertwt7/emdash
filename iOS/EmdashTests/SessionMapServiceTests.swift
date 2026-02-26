import XCTest
@testable import Emdash

final class SessionMapServiceTests: XCTestCase {

    // MARK: - Deterministic UUID

    func testDeterministicUuidConsistency() {
        let uuid1 = SessionMapService.deterministicUuid("test-task-id")
        let uuid2 = SessionMapService.deterministicUuid("test-task-id")
        XCTAssertEqual(uuid1, uuid2, "Same input should produce same UUID")
    }

    func testDeterministicUuidDifferentInputs() {
        let uuid1 = SessionMapService.deterministicUuid("task-1")
        let uuid2 = SessionMapService.deterministicUuid("task-2")
        XCTAssertNotEqual(uuid1, uuid2, "Different inputs should produce different UUIDs")
    }

    func testDeterministicUuidFormat() {
        let uuid = SessionMapService.deterministicUuid("test-input")
        // UUID format: 8-4-4-4-12 hex chars
        let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        XCTAssertNotNil(uuid.range(of: pattern, options: .regularExpression),
                        "UUID should match standard format: \(uuid)")
    }

    func testDeterministicUuidVersion4Bits() {
        let uuid = SessionMapService.deterministicUuid("version-test")
        let parts = uuid.split(separator: "-")
        XCTAssertEqual(parts.count, 5)
        // Third group should start with '4' (version 4)
        XCTAssertTrue(parts[2].hasPrefix("4"), "UUID version should be 4, got: \(parts[2])")
        // Fourth group first char should be 8, 9, a, or b (variant)
        let variantChar = parts[3].first!
        XCTAssertTrue("89ab".contains(variantChar), "UUID variant char should be 8-b, got: \(variantChar)")
    }

    // MARK: - Session Isolation Logic

    func testSessionIsolationSkipsNonClaudeProviders() {
        let service = SessionMapService()
        // Codex has no sessionIdFlag
        let codexProvider = ProviderRegistry.provider(for: .codex)!
        let result = service.applySessionIsolation(
            provider: codexProvider,
            ptyId: "codex-main-task123",
            cwd: "/tmp/project",
            isResume: false
        )
        XCTAssertNil(result, "Non-Claude providers should return nil")
    }

    func testSessionIsolationAssignsUuidForNewMainChat() {
        let service = SessionMapService()
        let claudeProvider = ProviderRegistry.provider(for: .claude)!
        let result = service.applySessionIsolation(
            provider: claudeProvider,
            ptyId: "claude-main-task456",
            cwd: "/tmp/project",
            isResume: false
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.first, "--session-id")
        XCTAssertEqual(result?.count, 2)
    }

    func testSessionIsolationResumesKnownSession() {
        let service = SessionMapService()
        let claudeProvider = ProviderRegistry.provider(for: .claude)!
        let ptyId = "claude-main-task789"
        let cwd = "/tmp/project"

        // First call creates session
        let first = service.applySessionIsolation(
            provider: claudeProvider, ptyId: ptyId, cwd: cwd, isResume: false
        )
        XCTAssertNotNil(first)
        let uuid = first![1]

        // Second call should resume
        let second = service.applySessionIsolation(
            provider: claudeProvider, ptyId: ptyId, cwd: cwd, isResume: false
        )
        XCTAssertEqual(second?.first, "--resume")
        XCTAssertEqual(second?[1], uuid)
    }

    func testSessionIsolationReturnsNilForGenericResume() {
        let service = SessionMapService()
        let claudeProvider = ProviderRegistry.provider(for: .claude)!

        // Resume with no prior session and no other sessions = nil (generic resume)
        let result = service.applySessionIsolation(
            provider: claudeProvider,
            ptyId: "claude-main-task000",
            cwd: "/tmp/project",
            isResume: true
        )
        XCTAssertNil(result, "Resuming with no isolation should return nil for generic resume")
    }

    func testSessionIsolationAdditionalChat() {
        let service = SessionMapService()
        let claudeProvider = ProviderRegistry.provider(for: .claude)!

        let result = service.applySessionIsolation(
            provider: claudeProvider,
            ptyId: "claude-chat-conv123",
            cwd: "/tmp/project",
            isResume: false
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.first, "--session-id")
    }
}
