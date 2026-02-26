import Foundation
import SwiftData

/// Orchestrates agent lifecycle: detection, task creation, agent spawning, and cleanup.
/// Port of Electron's ptyManager + TaskLifecycleService for remote-only mode.
@MainActor
final class AgentManager: ObservableObject {
    private let appState: AppState
    private lazy var remotePtyService = RemotePtyService(sshService: appState.sshService)

    @Published var runningAgents: [String: AgentInfo] = [:] // keyed by PTY ID

    /// Cached agent detection results per connection. Avoids re-running `which` on every project open.
    private var detectionCache: [String: DetectionCacheEntry] = [:]
    private let detectionCacheTTL: TimeInterval = 300 // 5 minutes

    struct DetectionCacheEntry {
        let providers: [ProviderId]
        let timestamp: Date
    }

    struct AgentInfo: Identifiable {
        let id: String // PTY ID
        let providerId: ProviderId
        let taskId: String
        let projectId: String
        let connectionId: String
        var status: AgentStatus = .starting
    }

    enum AgentStatus {
        case starting
        case running
        case stopped
        case failed(String)
    }

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Agent Detection (with caching)

    /// Detect which CLI agents are installed on a remote server.
    /// Results are cached for 5 minutes per connection to avoid redundant SSH calls.
    func detectAgents(connectionId: String, forceRefresh: Bool = false) async -> [ProviderId] {
        // Check cache first
        if !forceRefresh,
           let cached = detectionCache[connectionId],
           Date().timeIntervalSince(cached.timestamp) < detectionCacheTTL
        {
            Log.agent.debug("Using cached detection for \(connectionId): \(cached.providers.count) agents")
            appState.detectedAgents[connectionId] = cached.providers
            return cached.providers
        }

        var detected: [ProviderId] = []
        let sshService = appState.sshService

        // Prepend common version manager shim/bin paths to PATH, then source
        // shell profiles. SSH exec channels are non-interactive, so .bashrc's
        // "[ -z $PS1 ] && return" guard prevents tools like mise/nvm/asdf from
        // activating. Adding their paths explicitly ensures `command -v` finds
        // binaries installed via version managers (mise, asdf, volta, nvm, fnm).
        let extraPaths = [
            "$HOME/.local/share/mise/shims",   // mise (formerly rtx)
            "$HOME/.asdf/shims",               // asdf
            "$HOME/.volta/bin",                 // volta
            "$HOME/.local/bin",                 // pipx, user-local installs
            "$HOME/.npm-global/bin",            // npm global (custom prefix)
            "$HOME/.nvm/current/bin",           // nvm (if 'current' symlink exists)
            "$HOME/.fnm/aliases/default/bin",   // fnm
            "/usr/local/bin",                   // homebrew (macOS), manual installs
            "/home/linuxbrew/.linuxbrew/bin",   // homebrew (Linux)
        ].joined(separator: ":")
        let profileSetup = "export PATH=\"\(extraPaths):$PATH\"; . ~/.profile 2>/dev/null; . ~/.bashrc 2>/dev/null; . ~/.bash_profile 2>/dev/null"

        for provider in ProviderRegistry.detectableProviders {
            for command in provider.commands {
                do {
                    let result = try await sshService.executeCommand(
                        connectionId: connectionId,
                        command: "\(profileSetup); command -v \(command) 2>/dev/null"
                    )
                    if result.exitCode == 0 && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        detected.append(provider.id)
                        break // Found this provider, move to next
                    }
                } catch {
                    continue
                }
            }
        }

        // Update cache
        detectionCache[connectionId] = DetectionCacheEntry(providers: detected, timestamp: Date())

        Log.agent.info("Detected \(detected.count) agents on \(connectionId): \(detected.map(\.rawValue))")
        appState.detectedAgents[connectionId] = detected
        return detected
    }

    /// Invalidate detection cache for a connection (e.g., after reconnection).
    func invalidateDetectionCache(connectionId: String) {
        detectionCache.removeValue(forKey: connectionId)
    }

    func invalidateAllDetectionCache() {
        detectionCache.removeAll()
    }

    // MARK: - Task + Agent Lifecycle

    /// Create a task, set up worktree, and spawn the agent.
    func createAndStartTask(
        project: ProjectModel,
        name: String,
        providerId: ProviderId,
        initialPrompt: String?,
        autoApprove: Bool = true,
        env: [String: String] = [:],
        modelContext: ModelContext
    ) async throws -> AgentTask {
        guard let connectionId = project.connectionId else {
            throw AgentManagerError.noSSHConnection
        }
        guard let provider = ProviderRegistry.provider(for: providerId) else {
            throw AgentManagerError.unknownProvider(providerId.rawValue)
        }

        // 1. Create worktree on remote
        let worktreeInfo = try await appState.remoteGitService.createWorktree(
            connectionId: connectionId,
            projectPath: project.remotePath,
            taskName: name,
            baseRef: project.baseRef
        )

        // 2. Create task in local DB
        let task = AgentTask(
            name: name,
            project: project,
            branch: worktreeInfo.branch,
            worktreePath: worktreeInfo.path,
            status: .idle,
            agentId: providerId.rawValue
        )
        modelContext.insert(task)

        // 3. Create main conversation
        let conversation = Conversation(
            title: "Main",
            task: task,
            providerId: providerId.rawValue,
            isActive: true,
            isMain: true,
            displayOrder: 0
        )
        modelContext.insert(conversation)

        try modelContext.save()

        // 4. Spawn the agent
        let ptyId = PtyIdHelper.make(providerId: providerId, kind: .main, suffix: task.id)
        try await spawnAgent(
            ptyId: ptyId,
            connectionId: connectionId,
            provider: provider,
            cwd: worktreeInfo.path,
            initialPrompt: initialPrompt,
            autoApprove: autoApprove,
            env: env,
            taskId: task.id,
            projectId: project.id,
            isResume: false
        )

        task.status = .running
        try modelContext.save()

        return task
    }

    /// Resume a stopped task's agent, optionally with a follow-up prompt.
    /// If the worktree directory doesn't exist on the remote (e.g., original creation
    /// failed silently, or remote was cleaned up), it will be recreated automatically.
    /// When `followUpPrompt` is provided, it's passed as the initial prompt alongside
    /// resume flags (e.g., `claude --resume <uuid> "follow-up"`), matching Electron behavior.
    func resumeTask(
        task: AgentTask,
        followUpPrompt: String? = nil,
        modelContext: ModelContext
    ) async throws {
        guard let project = task.project,
              let connectionId = project.connectionId
        else {
            throw AgentManagerError.noSSHConnection
        }
        guard let agentIdStr = task.agentId,
              let providerId = ProviderId(rawValue: agentIdStr),
              let provider = ProviderRegistry.provider(for: providerId)
        else {
            throw AgentManagerError.unknownProvider(task.agentId ?? "nil")
        }
        guard var cwd = task.worktreePath else {
            throw AgentManagerError.noWorktree
        }

        // Verify the worktree directory exists on the remote.
        // It may be missing if the original creation failed silently
        // or the remote was cleaned up between sessions.
        let checkResult = try await appState.sshService.executeCommand(
            connectionId: connectionId,
            command: "test -d \(ShellEscape.quoteShellArg(cwd))"
        )

        if checkResult.exitCode != 0 {
            Log.agent.warning("Worktree not found at \(cwd), recreating for resume...")
            let worktreeInfo = try await appState.remoteGitService.createWorktree(
                connectionId: connectionId,
                projectPath: project.remotePath,
                taskName: task.name,
                baseRef: project.baseRef
            )
            task.worktreePath = worktreeInfo.path
            task.branch = worktreeInfo.branch
            cwd = worktreeInfo.path
            try modelContext.save()
            Log.agent.info("Recreated worktree at \(cwd)")
        }

        let ptyId = PtyIdHelper.make(providerId: providerId, kind: .main, suffix: task.id)

        // Stop existing agent if any
        if runningAgents[ptyId] != nil {
            await stopAgent(ptyId: ptyId)
        }

        // When a follow-up prompt is provided, use isResume: false to avoid
        // conflicting resume flags. E.g., Gemini's --resume treats the next
        // positional arg as a session ID, so `--resume "message"` fails with
        // "Invalid session identifier". With isResume: false:
        //   - Claude still gets --session-id via applySessionIsolation() (continuity preserved)
        //   - Gemini/others get a fresh invocation with just the prompt
        let hasPrompt = followUpPrompt != nil
        try await spawnAgent(
            ptyId: ptyId,
            connectionId: connectionId,
            provider: provider,
            cwd: cwd,
            initialPrompt: followUpPrompt,
            autoApprove: true,
            env: [:],
            taskId: task.id,
            projectId: project.id,
            isResume: !hasPrompt
        )

        task.status = .running
        task.updatedAt = Date()
        try modelContext.save()
    }

    /// Spawn an agent in a remote PTY session.
    private func spawnAgent(
        ptyId: String,
        connectionId: String,
        provider: ProviderDefinition,
        cwd: String,
        initialPrompt: String?,
        autoApprove: Bool,
        env: [String: String],
        taskId: String,
        projectId: String,
        isResume: Bool
    ) async throws {
        let options = RemotePtyService.StartOptions(
            id: ptyId,
            connectionId: connectionId,
            cwd: cwd,
            provider: provider,
            autoApprove: autoApprove,
            initialPrompt: initialPrompt,
            env: env,
            isResume: isResume
        )

        let session = try await remotePtyService.startSession(options: options)

        let agentInfo = AgentInfo(
            id: ptyId,
            providerId: provider.id,
            taskId: taskId,
            projectId: projectId,
            connectionId: connectionId,
            status: .running
        )
        runningAgents[ptyId] = agentInfo

        // Track session events — when the SSH session ends, update both
        // the in-memory agent info AND the persisted task status in SwiftData.
        // Without this, the task stays .running forever after session close,
        // hiding the resume banner and showing a stuck black terminal.
        session.onExit = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.runningAgents[ptyId]?.status = .stopped
                self.appState.activeTerminals.removeValue(forKey: ptyId)
                self.markTaskIdle(taskId: taskId)
            }
        }

        // Store terminal session in app state
        appState.activeTerminals[ptyId] = TerminalSession(
            id: ptyId,
            connectionId: connectionId,
            providerId: provider.id,
            taskId: taskId
        )
    }

    /// Update a task's status to .idle when its SSH session ends.
    /// Uses SwiftData's mainContext to persist the change so the UI reacts immediately.
    private func markTaskIdle(taskId: String) {
        guard let context = appState.modelContainer?.mainContext else {
            Log.agent.warning("No model context available to update task status")
            return
        }

        let targetId = taskId
        let descriptor = FetchDescriptor<AgentTask>(
            predicate: #Predicate<AgentTask> { task in
                task.id == targetId
            }
        )

        guard let task = try? context.fetch(descriptor).first else {
            Log.agent.warning("Task \(taskId) not found in database")
            return
        }

        if task.status == .running {
            task.status = .idle
            task.updatedAt = Date()
            try? context.save()
            Log.agent.info("Session ended — task '\(task.name)' marked idle")
        }
    }

    /// Add an additional agent conversation to an existing task.
    func addConversation(
        task: AgentTask,
        providerId: ProviderId,
        title: String? = nil,
        initialPrompt: String? = nil,
        autoApprove: Bool = true,
        env: [String: String] = [:],
        modelContext: ModelContext
    ) async throws -> Conversation {
        guard let project = task.project,
              let connectionId = project.connectionId else
        {
            throw AgentManagerError.noSSHConnection
        }
        guard let provider = ProviderRegistry.provider(for: providerId) else {
            throw AgentManagerError.unknownProvider(providerId.rawValue)
        }
        guard let cwd = task.worktreePath else {
            throw AgentManagerError.noWorktree
        }

        let order = (task.conversations?.count ?? 0)
        let displayTitle = title ?? "\(provider.name) #\(order + 1)"

        let conversation = Conversation(
            title: displayTitle,
            task: task,
            providerId: providerId.rawValue,
            isActive: false,
            isMain: false,
            displayOrder: order
        )
        modelContext.insert(conversation)
        try modelContext.save()

        // Spawn additional agent
        let ptyId = PtyIdHelper.make(providerId: providerId, kind: .chat, suffix: conversation.id)
        try await spawnAgent(
            ptyId: ptyId,
            connectionId: connectionId,
            provider: provider,
            cwd: cwd,
            initialPrompt: initialPrompt,
            autoApprove: autoApprove,
            env: env,
            taskId: task.id,
            projectId: project.id,
            isResume: false
        )

        return conversation
    }

    // MARK: - Agent Control

    /// Send text input to an agent.
    func sendInput(ptyId: String, text: String) async throws {
        try await remotePtyService.write(sessionId: ptyId, text: text)
    }

    /// Send raw data to an agent.
    func sendData(ptyId: String, data: Data) async throws {
        try await remotePtyService.write(sessionId: ptyId, data: data)
    }

    /// Resize an agent's terminal.
    func resizeTerminal(ptyId: String, cols: Int, rows: Int) async throws {
        try await remotePtyService.resize(sessionId: ptyId, cols: cols, rows: rows)
    }

    /// Stop an agent.
    func stopAgent(ptyId: String) async {
        await remotePtyService.stopSession(ptyId)
        runningAgents.removeValue(forKey: ptyId)
        appState.activeTerminals.removeValue(forKey: ptyId)
    }

    /// Stop all agents for a task.
    func stopAllAgents(taskId: String) async {
        let ptyIds = runningAgents.values
            .filter { $0.taskId == taskId }
            .map(\.id)

        for ptyId in ptyIds {
            await stopAgent(ptyId: ptyId)
        }
    }

    // MARK: - Task Cleanup

    /// Full task teardown: stop agents, remove worktree.
    func teardownTask(
        task: AgentTask,
        modelContext: ModelContext
    ) async throws {
        // Stop all agents
        await stopAllAgents(taskId: task.id)

        // Remove remote worktree if exists
        if let project = task.project,
           let connectionId = project.connectionId,
           let worktreePath = task.worktreePath
        {
            do {
                try await appState.remoteGitService.removeWorktree(
                    connectionId: connectionId,
                    projectPath: project.remotePath,
                    worktreePath: worktreePath,
                    branch: task.branch
                )
            } catch {
                Log.agent.error("Failed to remove worktree: \(error.localizedDescription)")
            }
        }

        // Delete from DB
        modelContext.delete(task)
        try modelContext.save()
    }

    /// Get output callback for a PTY session.
    func getSession(_ ptyId: String) async -> RemotePtySession? {
        await remotePtyService.getSession(ptyId)
    }

    /// Check if an agent is currently running for a task.
    func isAgentRunning(taskId: String) -> Bool {
        runningAgents.values.contains { $0.taskId == taskId && isActiveStatus($0.status) }
    }

    private func isActiveStatus(_ status: AgentStatus) -> Bool {
        switch status {
        case .starting, .running: return true
        case .stopped, .failed: return false
        }
    }
}

enum AgentManagerError: LocalizedError {
    case noSSHConnection
    case unknownProvider(String)
    case noWorktree

    var errorDescription: String? {
        switch self {
        case .noSSHConnection:
            return "Project has no SSH connection configured"
        case .unknownProvider(let id):
            return "Unknown provider: \(id)"
        case .noWorktree:
            return "Task has no worktree path"
        }
    }
}
