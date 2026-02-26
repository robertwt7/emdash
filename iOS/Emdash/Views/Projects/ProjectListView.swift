import SwiftUI
import SwiftData

/// Sidebar project and task list. Mirrors Electron's LeftSidebar.
struct ProjectListView: View {
    let projects: [ProjectModel]
    let onSelectProject: (ProjectModel) -> Void
    let onSelectTask: (AgentTask) -> Void

    @EnvironmentObject private var appState: AppState
    @State private var expandedProjects: Set<String> = []

    var body: some View {
        List {
            if projects.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("Add a remote project to get started")
                } actions: {
                    Button("Add Remote Project") {
                        appState.showingAddRemoteProject = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ForEach(projects) { project in
                    ProjectSection(
                        project: project,
                        isExpanded: expandedProjects.contains(project.id),
                        onToggleExpand: {
                            withAnimation {
                                if expandedProjects.contains(project.id) {
                                    expandedProjects.remove(project.id)
                                } else {
                                    expandedProjects.insert(project.id)
                                }
                            }
                        },
                        onSelectProject: {
                            onSelectProject(project)
                            expandedProjects.insert(project.id)
                        },
                        onSelectTask: onSelectTask
                    )
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Project Section

private struct ProjectSection: View {
    let project: ProjectModel
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onSelectProject: () -> Void
    let onSelectTask: (AgentTask) -> Void

    @EnvironmentObject private var appState: AppState
    @State private var showingCreateTask = false

    var body: some View {
        Section {
            // Project header row
            Button {
                onSelectProject()
            } label: {
                HStack(spacing: 8) {
                    ConnectionIndicator(
                        state: connectionState,
                        size: 8
                    )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)

                        if let conn = project.sshConnection {
                            Text(conn.host)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    // Expand/collapse chevron
                    Button {
                        onToggleExpand()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded {
                // New Task button
                Button {
                    showingCreateTask = true
                } label: {
                    Label("New Task", systemImage: "plus.circle")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)

                // Active tasks
                ForEach(project.activeTasks) { task in
                    TaskRow(
                        task: task,
                        isSelected: appState.activeTask?.id == task.id
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelectTask(task)
                    }
                    .contextMenu {
                        Button("Archive", systemImage: "archivebox") {
                            archiveTask(task)
                        }
                    }
                }

                // Archived tasks section
                if !project.archivedTasks.isEmpty {
                    DisclosureGroup("Archived (\(project.archivedTasks.count))") {
                        ForEach(project.archivedTasks) { task in
                            TaskRow(task: task, isSelected: false)
                                .opacity(0.6)
                                .contextMenu {
                                    Button("Restore", systemImage: "arrow.uturn.backward") {
                                        restoreTask(task)
                                    }
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        // TODO: Implement delete
                                    }
                                }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $showingCreateTask) {
            CreateTaskView(project: project)
        }
    }

    private var connectionState: ConnectionState {
        guard let id = project.connectionId else { return .disconnected }
        return appState.connectionState(for: id)
    }

    private func archiveTask(_ task: AgentTask) {
        task.archivedAt = Date()
        task.status = .archived
    }

    private func restoreTask(_ task: AgentTask) {
        task.archivedAt = nil
        task.status = .idle
    }
}

// MARK: - Task Row

private struct TaskRow: View {
    let task: AgentTask
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            statusIcon

            VStack(alignment: .leading, spacing: 1) {
                Text(task.name)
                    .font(.callout)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if let agentId = task.agentId,
                       let provider = ProviderId(rawValue: agentId),
                       let def = ProviderRegistry.provider(for: provider)
                    {
                        Text(def.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if task.status == .idle {
                        Text("· Stopped")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            if task.isRunning {
                ProgressView()
                    .scaleEffect(0.6)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.status {
        case .running:
            Image(systemName: "play.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.blue)
                .font(.caption)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        case .archived:
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .idle:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}
