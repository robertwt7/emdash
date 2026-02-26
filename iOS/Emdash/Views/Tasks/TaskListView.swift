import SwiftUI

/// Task list for a project, used in various contexts.
struct TaskListView: View {
    let tasks: [AgentTask]
    let onSelect: (AgentTask) -> Void

    @EnvironmentObject private var appState: AppState

    var body: some View {
        ForEach(tasks) { task in
            Button {
                onSelect(task)
            } label: {
                TaskListRow(task: task, isActive: appState.activeTask?.id == task.id)
            }
            .buttonStyle(.plain)
        }
    }
}

struct TaskListRow: View {
    let task: AgentTask
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            statusIcon
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.name)
                    .font(.body.weight(isActive ? .semibold : .regular))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let agentId = task.agentId,
                       let pid = ProviderId(rawValue: agentId),
                       let provider = ProviderRegistry.provider(for: pid)
                    {
                        Text(provider.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let branch = task.branch {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 8))
                            Text(branch)
                                .lineLimit(1)
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // Conversation count
            let convCount = task.conversations?.count ?? 0
            if convCount > 1 {
                Text("\(convCount)")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }

            if task.isRunning {
                ProgressView()
                    .scaleEffect(0.6)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isActive ? Color.accentColor.opacity(0.1) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.status {
        case .running:
            Image(systemName: "play.circle.fill")
                .foregroundStyle(.green)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.blue)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .archived:
            Image(systemName: "archivebox.fill")
                .foregroundStyle(.secondary)
        case .idle:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }
}
