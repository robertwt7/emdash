import SwiftUI
import SwiftData
import Combine

// MARK: - Navigation

enum NavigationDestination: Hashable {
    case home
    case project(ProjectModel)
    case task(AgentTask)
    case settings
    case addRemoteProject
}

enum ConnectionState: String, Codable {
    case connecting
    case connected
    case disconnected
    case error
    case reconnecting
}

// MARK: - State Persistence Keys

private enum StateKeys {
    static let activeProjectId = "emdash:activeProjectId"
    static let activeTaskId = "emdash:activeTaskId"
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    // Navigation
    @Published var selectedProject: ProjectModel?
    @Published var activeTask: AgentTask?
    @Published var showingSettings = false
    @Published var showingAddRemoteProject = false
    @Published var showingCreateTask = false
    @Published var showingHomeView = true
    @Published var navigationPath = NavigationPath()

    // Connection states keyed by SSHConnection ID
    @Published var connectionStates: [String: ConnectionState] = [:]

    // Active terminal sessions keyed by PTY ID
    @Published var activeTerminals: [String: TerminalSession] = [:]

    // Services (initialized after model container is set)
    var modelContainer: ModelContainer?
    private(set) lazy var sshService = SSHService()
    private(set) lazy var keychainService = KeychainService()
    private(set) lazy var agentManager = AgentManager(appState: self)
    private(set) lazy var remoteGitService = RemoteGitService(sshService: sshService)
    private(set) lazy var connectionMonitor = SSHConnectionMonitor(sshService: sshService, appState: self)

    // Detected agents on remote
    @Published var detectedAgents: [String: [ProviderId]] = [:] // connectionId -> providers

    // MARK: - Initialization

    func setupConnectionMonitor() {
        connectionMonitor.onReconnectNeeded = { [weak self] connectionId, config, attempt in
            guard let self else { return false }
            Log.ssh.info("Reconnect attempt \(attempt) for \(connectionId)")
            do {
                let password = self.keychainService.getPassword(connectionId: connectionId)
                let passphrase = self.keychainService.getPassphrase(connectionId: connectionId)
                _ = try await self.sshService.connect(
                    connectionId: connectionId,
                    host: config.host,
                    port: config.port,
                    username: config.username,
                    authType: config.authType,
                    privateKeyPath: config.privateKeyPath,
                    password: password,
                    passphrase: passphrase
                )
                return true
            } catch {
                Log.ssh.error("Reconnect failed: \(error.localizedDescription)")
                return false
            }
        }

        connectionMonitor.onReconnectFailed = { connectionId, error in
            Log.ssh.error("Connection \(connectionId) permanently lost: \(error)")
        }
    }

    // MARK: - Navigation

    func selectProject(_ project: ProjectModel) {
        selectedProject = project
        activeTask = nil
        showingHomeView = false
        saveActiveIds(projectId: project.id, taskId: nil)
    }

    func selectTask(_ task: AgentTask) {
        activeTask = task
        showingHomeView = false
        saveActiveIds(projectId: selectedProject?.id, taskId: task.id)
    }

    func goHome() {
        selectedProject = nil
        activeTask = nil
        showingHomeView = true
        saveActiveIds(projectId: nil, taskId: nil)
    }

    // MARK: - Connection State

    func connectionState(for connectionId: String) -> ConnectionState {
        connectionStates[connectionId] ?? .disconnected
    }

    func updateConnectionState(_ connectionId: String, state: ConnectionState) {
        connectionStates[connectionId] = state
    }

    /// Connect to SSH and start monitoring.
    func connectAndMonitor(
        connection: SSHConnectionModel
    ) async throws {
        let connId = connection.id
        updateConnectionState(connId, state: .connecting)

        let password = keychainService.getPassword(connectionId: connId)
        let passphrase = keychainService.getPassphrase(connectionId: connId)

        do {
            _ = try await sshService.connect(
                connectionId: connId,
                host: connection.host,
                port: connection.port,
                username: connection.username,
                authType: connection.authType,
                privateKeyPath: connection.privateKeyPath,
                password: password,
                passphrase: passphrase
            )

            updateConnectionState(connId, state: .connected)

            // Start monitoring for health checks and auto-reconnect
            connectionMonitor.startMonitoring(
                connectionId: connId,
                config: SSHConnectionMonitor.ReconnectConfig(
                    host: connection.host,
                    port: connection.port,
                    username: connection.username,
                    authType: connection.authType,
                    privateKeyPath: connection.privateKeyPath
                )
            )
        } catch {
            updateConnectionState(connId, state: .error)
            throw error
        }
    }

    // MARK: - State Persistence

    /// Save active project and task IDs to UserDefaults for restoration on next launch.
    func saveActiveIds(projectId: String?, taskId: String?) {
        let defaults = UserDefaults.standard
        if let projectId {
            defaults.set(projectId, forKey: StateKeys.activeProjectId)
        } else {
            defaults.removeObject(forKey: StateKeys.activeProjectId)
        }
        if let taskId {
            defaults.set(taskId, forKey: StateKeys.activeTaskId)
        } else {
            defaults.removeObject(forKey: StateKeys.activeTaskId)
        }
    }

    /// Restore last active project and task from UserDefaults.
    /// Called during app initialization after SwiftData container is ready.
    func restoreActiveState(projects: [ProjectModel]) {
        let defaults = UserDefaults.standard
        guard let projectId = defaults.string(forKey: StateKeys.activeProjectId) else {
            // No saved state — show home
            showingHomeView = true
            return
        }

        guard let project = projects.first(where: { $0.id == projectId }) else {
            // Saved project no longer exists
            saveActiveIds(projectId: nil, taskId: nil)
            showingHomeView = true
            return
        }

        selectedProject = project
        showingHomeView = false

        if let taskId = defaults.string(forKey: StateKeys.activeTaskId),
           let task = project.activeTasks.first(where: { $0.id == taskId })
        {
            activeTask = task
        }
    }
}

// MARK: - Terminal Session

struct TerminalSession: Identifiable {
    let id: String // PTY ID format: {providerId}-main-{taskId}
    let connectionId: String
    let providerId: ProviderId
    let taskId: String
    var isActive: Bool = true
}
