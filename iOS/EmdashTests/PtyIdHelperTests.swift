import XCTest
@testable import Emdash

final class PtyIdHelperTests: XCTestCase {

    func testMakePtyId() {
        let id = PtyIdHelper.make(providerId: .claude, kind: .main, suffix: "abc123")
        XCTAssertEqual(id, "claude-main-abc123")
    }

    func testMakeChatPtyId() {
        let id = PtyIdHelper.make(providerId: .codex, kind: .chat, suffix: "conv456")
        XCTAssertEqual(id, "codex-chat-conv456")
    }

    func testParsePtyId() {
        let result = PtyIdHelper.parse("claude-main-abc123")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.providerId, .claude)
        XCTAssertEqual(result?.kind, .main)
        XCTAssertEqual(result?.suffix, "abc123")
    }

    func testParseChatPtyId() {
        let result = PtyIdHelper.parse("codex-chat-conv456")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.providerId, .codex)
        XCTAssertEqual(result?.kind, .chat)
        XCTAssertEqual(result?.suffix, "conv456")
    }

    func testParseInvalidPtyId() {
        XCTAssertNil(PtyIdHelper.parse("invalid"))
        XCTAssertNil(PtyIdHelper.parse(""))
        XCTAssertNil(PtyIdHelper.parse("unknown-main-123"))
    }

    func testParseLongProviderId() {
        // "continue" is longer than "co" prefix of "codex" — test prefix ambiguity
        let result = PtyIdHelper.parse("continue-main-task1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.providerId, .continueAgent)
    }
}
