import XCTest
@testable import Emdash

/// Tests for the connection monitor's configuration and constants.
/// Full integration tests require a real SSH connection.
final class SSHConnectionMonitorTests: XCTestCase {

    func testReconnectConfigInitialization() {
        let config = SSHConnectionMonitor.ReconnectConfig(
            host: "example.com",
            port: 22,
            username: "user",
            authType: .key,
            privateKeyPath: "~/.ssh/id_ed25519"
        )
        XCTAssertEqual(config.host, "example.com")
        XCTAssertEqual(config.port, 22)
        XCTAssertEqual(config.username, "user")
        XCTAssertEqual(config.authType, .key)
        XCTAssertEqual(config.privateKeyPath, "~/.ssh/id_ed25519")
    }

    func testConnectionMetricsDefaults() {
        let metrics = SSHConnectionMonitor.ConnectionMetrics()
        XCTAssertEqual(metrics.totalReconnects, 0)
        XCTAssertNil(metrics.lastConnectedAt)
        XCTAssertNil(metrics.lastDisconnectedAt)
    }
}
