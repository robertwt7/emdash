import Foundation

/// Monitors SSH connection health and handles automatic reconnection.
/// Port of Electron's SshConnectionMonitor — 30s health checks, 3 retries with [1s, 5s, 15s] backoff.
@MainActor
final class SSHConnectionMonitor: ObservableObject {
    private let sshService: SSHService
    private weak var appState: AppState?

    // Static constants avoid closure capture issues
    static let healthCheckIntervalSeconds: TimeInterval = 30
    static let maxReconnectAttempts = 3
    static let reconnectBackoffMs: [Int] = [1000, 5000, 15000]

    private var monitoredConnections: [String: MonitoredConnection] = [:]
    private var healthCheckTask: Task<Void, Never>?

    // MARK: - Types

    struct MonitoredConnection {
        let connectionId: String
        let config: ReconnectConfig
        var state: ConnectionState = .connected
        var reconnectAttempts: Int = 0
        var lastHealthCheck: Date = Date()
        var metrics: ConnectionMetrics = ConnectionMetrics()
    }

    struct ReconnectConfig {
        let host: String
        let port: Int
        let username: String
        let authType: AuthType
        let privateKeyPath: String?
    }

    struct ConnectionMetrics {
        var totalReconnects: Int = 0
        var lastConnectedAt: Date?
        var lastDisconnectedAt: Date?
    }

    /// Called when reconnection should be attempted. Parameters: connectionId, config, attempt number.
    var onReconnectNeeded: ((String, ReconnectConfig, Int) async -> Bool)?

    /// Called when all reconnect attempts have been exhausted.
    var onReconnectFailed: ((String, String) -> Void)?

    init(sshService: SSHService, appState: AppState) {
        self.sshService = sshService
        self.appState = appState
    }

    // MARK: - Start/Stop Monitoring

    func startMonitoring(connectionId: String, config: ReconnectConfig) {
        self.monitoredConnections[connectionId] = MonitoredConnection(
            connectionId: connectionId,
            config: config,
            state: .connected,
            metrics: ConnectionMetrics(lastConnectedAt: Date())
        )

        if self.healthCheckTask == nil {
            self.startHealthCheckLoop()
        }

        Log.ssh.info("Monitoring started")
    }

    func stopMonitoring(connectionId: String) {
        self.monitoredConnections.removeValue(forKey: connectionId)

        if self.monitoredConnections.isEmpty {
            self.healthCheckTask?.cancel()
            self.healthCheckTask = nil
        }
    }

    func stopAll() {
        self.healthCheckTask?.cancel()
        self.healthCheckTask = nil
        self.monitoredConnections.removeAll()
    }

    // MARK: - Disconnect Handling

    func handleDisconnect(connectionId: String) {
        guard var monitored = self.monitoredConnections[connectionId] else { return }
        guard monitored.state != .reconnecting && monitored.state != .disconnected else { return }

        monitored.state = .error
        monitored.metrics.lastDisconnectedAt = Date()
        self.monitoredConnections[connectionId] = monitored

        self.updateState(connectionId, state: .error)
        self.attemptReconnect(connectionId: connectionId)
    }

    func handleReconnectSuccess(connectionId: String) {
        guard var monitored = self.monitoredConnections[connectionId] else { return }
        monitored.state = .connected
        monitored.reconnectAttempts = 0
        monitored.metrics.lastConnectedAt = Date()
        self.monitoredConnections[connectionId] = monitored

        self.updateState(connectionId, state: .connected)
    }

    // MARK: - Health Check Loop

    private func startHealthCheckLoop() {
        let interval = Self.healthCheckIntervalSeconds
        self.healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await self?.performHealthChecks()
            }
        }
    }

    private func performHealthChecks() async {
        for (connectionId, monitored) in self.monitoredConnections {
            guard monitored.state == .connected else { continue }

            let isAlive = await self.sshService.isConnected(connectionId)

            if !isAlive {
                var updated = monitored
                updated.state = .error
                updated.metrics.lastDisconnectedAt = Date()
                self.monitoredConnections[connectionId] = updated

                self.updateState(connectionId, state: .error)
                self.attemptReconnect(connectionId: connectionId)
            } else {
                var updated = monitored
                updated.lastHealthCheck = Date()
                self.monitoredConnections[connectionId] = updated
            }
        }
    }

    // MARK: - Reconnection with Backoff

    private func attemptReconnect(connectionId: String) {
        guard var monitored = self.monitoredConnections[connectionId] else { return }

        let maxAttempts = Self.maxReconnectAttempts
        let backoff = Self.reconnectBackoffMs

        if monitored.reconnectAttempts >= maxAttempts {
            monitored.state = .disconnected
            self.monitoredConnections[connectionId] = monitored
            self.updateState(connectionId, state: .disconnected)
            let msg = "Max reconnection attempts (\(maxAttempts)) reached"
            self.onReconnectFailed?(connectionId, msg)
            Log.ssh.error("Reconnection failed — max attempts reached")
            return
        }

        monitored.reconnectAttempts += 1
        monitored.state = .reconnecting
        monitored.metrics.totalReconnects += 1
        self.monitoredConnections[connectionId] = monitored

        self.updateState(connectionId, state: .reconnecting)

        let attempt = monitored.reconnectAttempts
        let delayIndex = min(attempt - 1, backoff.count - 1)
        let delayMs = backoff[delayIndex]

        Log.ssh.info("Reconnect attempt \(attempt) of \(maxAttempts)")

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard let self else { return }

            guard let current = self.monitoredConnections[connectionId],
                  current.state == .reconnecting else { return }

            if let onReconnect = self.onReconnectNeeded {
                let success = await onReconnect(connectionId, current.config, attempt)
                if success {
                    self.handleReconnectSuccess(connectionId: connectionId)
                } else {
                    self.attemptReconnect(connectionId: connectionId)
                }
            }
        }
    }

    // MARK: - State

    private func updateState(_ connectionId: String, state: ConnectionState) {
        self.appState?.updateConnectionState(connectionId, state: state)
    }

    var activeConnectionCount: Int {
        self.monitoredConnections.values.filter { $0.state == .connected }.count
    }

    func connectionMetrics(for connectionId: String) -> ConnectionMetrics? {
        self.monitoredConnections[connectionId]?.metrics
    }
}
