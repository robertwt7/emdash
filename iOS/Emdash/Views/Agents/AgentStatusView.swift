import SwiftUI

/// Shows the status of running agents across all tasks.
struct AgentStatusView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            if appState.agentManager.runningAgents.isEmpty {
                ContentUnavailableView(
                    "No Running Agents",
                    systemImage: "person.3",
                    description: Text("Create a task to spawn agents")
                )
            } else {
                ForEach(Array(appState.agentManager.runningAgents.values), id: \.id) { agent in
                    AgentRow(agent: agent)
                }
            }
        }
        .navigationTitle("Running Agents")
    }
}

private struct AgentRow: View {
    let agent: AgentManager.AgentInfo

    var body: some View {
        HStack(spacing: 12) {
            if let provider = ProviderRegistry.provider(for: agent.providerId) {
                Image(systemName: provider.icon ?? "terminal")
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.body.weight(.medium))

                    Text("Task: \(agent.taskId.prefix(8))...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            statusBadge
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch agent.status {
        case .starting:
            Label("Starting", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.orange)
        case .running:
            Label("Running", systemImage: "play.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .stopped:
            Label("Stopped", systemImage: "stop.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let reason):
            Label("Failed", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .help(reason)
        }
    }
}
