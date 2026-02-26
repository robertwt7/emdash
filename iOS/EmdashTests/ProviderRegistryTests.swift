import XCTest
@testable import Emdash

final class ProviderRegistryTests: XCTestCase {

    func testAllProvidersExist() {
        XCTAssertEqual(ProviderRegistry.providers.count, 21)
    }

    func testProviderLookup() {
        let claude = ProviderRegistry.provider(for: .claude)
        XCTAssertNotNil(claude)
        XCTAssertEqual(claude?.name, "Claude Code")
        XCTAssertEqual(claude?.cli, "claude")
        XCTAssertEqual(claude?.autoApproveFlag, "--dangerously-skip-permissions")
        XCTAssertEqual(claude?.sessionIdFlag, "--session-id")
    }

    func testDetectableProviders() {
        let detectable = ProviderRegistry.detectableProviders
        // Goose is not detectable
        XCTAssertFalse(detectable.contains { $0.id == .goose })
        // Claude is detectable
        XCTAssertTrue(detectable.contains { $0.id == .claude })
    }

    func testProviderIdValidation() {
        XCTAssertTrue(ProviderRegistry.isValidProvider("claude"))
        XCTAssertTrue(ProviderRegistry.isValidProvider("codex"))
        XCTAssertFalse(ProviderRegistry.isValidProvider("nonexistent"))
    }

    func testKeystrokeInjectionProviders() {
        let amp = ProviderRegistry.provider(for: .amp)
        XCTAssertTrue(amp?.useKeystrokeInjection == true)

        let opencode = ProviderRegistry.provider(for: .opencode)
        XCTAssertTrue(opencode?.useKeystrokeInjection == true)

        let claude = ProviderRegistry.provider(for: .claude)
        XCTAssertFalse(claude?.useKeystrokeInjection == true)
    }

    func testProviderWithAutoStartCommand() {
        let rovo = ProviderRegistry.provider(for: .rovo)
        XCTAssertNotNil(rovo)
        XCTAssertNil(rovo?.cli)
        XCTAssertEqual(rovo?.autoStartCommand, "acli rovodev run")
        XCTAssertEqual(rovo?.effectiveCli, "acli")
    }
}
