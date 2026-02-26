import SwiftUI
import SwiftData

/// Project detail view showing tasks and project info.
/// Shown when a project is selected but no task is active.
struct ProjectDetailView: View {
    let project: ProjectModel
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showingCreateTask = false
    @State private var isConnecting = false
    @State private var detectedAgents: [ProviderId] = []
    @State private var showingDeleteConfirmation = false

    var body: some View {
        List {
            // Connection Status
            Section("Connection") {
                connectionStatusRow

                if let conn = project.sshConnection {
                    LabeledContent("Host", value: conn.host)
                    LabeledContent("Port", value: "\(conn.port)")
                    LabeledContent("User", value: conn.username)
                    LabeledContent("Auth", value: conn.authType.rawValue.capitalized)
                }

                LabeledContent("Path", value: project.remotePath)
            }

            // Git Info
            if project.gitBranch != nil || project.gitRemote != nil {
                Section("Git") {
                    if let branch = project.gitBranch {
                        LabeledContent("Branch", value: branch)
                    }
                    if let remote = project.gitRemote {
                        LabeledContent("Remote", value: remote)
                    }
                    if let baseRef = project.baseRef {
                        LabeledContent("Base Ref", value: baseRef)
                    }
                }
            }

            // Detected Agents
            if !detectedAgents.isEmpty {
                Section("Available Agents (\(detectedAgents.count))") {
                    ForEach(detectedAgents, id: \.self) { providerId in
                        if let provider = ProviderRegistry.provider(for: providerId) {
                            Label(provider.name, systemImage: provider.icon ?? "terminal")
                        }
                    }
                }
            }

            // Tasks
            Section("Tasks (\(project.activeTasks.count))") {
                ForEach(project.activeTasks) { task in
                    Button {
                        appState.selectTask(task)
                        if sizeClass != .regular {
                            appState.navigationPath.append(NavigationDestination.task(task))
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.name)
                                    .font(.body)
                                if let branch = task.branch {
                                    Text(branch)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()

                            taskStatusBadge(task)
                        }
                    }
                }

                Button {
                    showingCreateTask = true
                } label: {
                    Label("New Task", systemImage: "plus.circle")
                }
            }

            // Danger Zone
            Section {
                Button("Delete Project", role: .destructive) {
                    showingDeleteConfirmation = true
                }
            }
        }
        .navigationTitle(project.name)
        .refreshable {
            await refresh()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreateTask = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingCreateTask) {
            CreateTaskView(project: project)
        }
        .confirmationDialog("Delete Project?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteProject()
            }
        } message: {
            Text("This will remove the project from Emdash. Remote files will not be affected.")
        }
        .task {
            await connectAndDetect()
        }
    }

    // MARK: - Connection Status

    private var connectionStatusRow: some View {
        HStack {
            ConnectionIndicator(state: connectionState, size: 10)
            Text(connectionState.rawValue.capitalized)
                .font(.callout)

            Spacer()

            if connectionState == .disconnected || connectionState == .error {
                Button("Connect") {
                    Task { await connectAndDetect() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isConnecting)
            } else if connectionState == .reconnecting {
                Text("Reconnecting...")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if isConnecting {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
    }

    private var connectionState: ConnectionState {
        guard let id = project.connectionId else { return .disconnected }
        return appState.connectionState(for: id)
    }

    // MARK: - Task Status Badge

    @ViewBuilder
    private func taskStatusBadge(_ task: AgentTask) -> some View {
        switch task.status {
        case .running:
            ProgressView()
                .scaleEffect(0.7)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        case .idle:
            Image(systemName: "pause.circle")
                .foregroundStyle(.orange)
                .font(.caption)
        case .archived:
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    // MARK: - Actions

    /// Pull-to-refresh: reconnect, re-detect agents, refresh git info.
    private func refresh() async {
        guard let conn = project.sshConnection else { return }

        // Force refresh agent detection
        detectedAgents = await appState.agentManager.detectAgents(
            connectionId: conn.id, forceRefresh: true
        )

        // Refresh git info
        do {
            let branch = try await appState.remoteGitService.getCurrentBranch(
                connectionId: conn.id, cwd: project.remotePath
            )
            project.gitBranch = branch

            let remote = try await appState.remoteGitService.getRemoteUrl(
                connectionId: conn.id, cwd: project.remotePath
            )
            project.gitRemote = remote
        } catch {
            Log.git.error("Git refresh failed: \(error.localizedDescription)")
        }
    }

    private func connectAndDetect() async {
        guard let conn = project.sshConnection else { return }
        isConnecting = true
        defer { isConnecting = false }

        do {
            try await appState.connectAndMonitor(connection: conn)

            // Detect available agents (uses cache if fresh)
            detectedAgents = await appState.agentManager.detectAgents(connectionId: conn.id)

            // Fetch git info if not already set
            if project.gitBranch == nil {
                let branch = try? await appState.remoteGitService.getCurrentBranch(
                    connectionId: conn.id, cwd: project.remotePath
                )
                project.gitBranch = branch
                let remote = try? await appState.remoteGitService.getRemoteUrl(
                    connectionId: conn.id, cwd: project.remotePath
                )
                project.gitRemote = remote
            }
        } catch {
            Log.ssh.error("Connection failed: \(error.localizedDescription)")
        }
    }

    private func deleteProject() {
        // Stop monitoring and disconnect
        if let connId = project.connectionId {
            appState.connectionMonitor.stopMonitoring(connectionId: connId)
            Task {
                await appState.sshService.disconnect(connectionId: connId)
            }
        }

        if appState.selectedProject?.id == project.id {
            appState.goHome()
        }

        modelContext.delete(project)
        try? modelContext.save()
    }
}
