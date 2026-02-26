import SwiftUI
import SwiftData

/// Home/welcome screen showing quick actions and recent projects.
struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProjectModel.updatedAt, order: .reverse) private var projects: [ProjectModel]

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.blue)

                    Text("Emdash")
                        .font(.largeTitle.bold())

                    Text("Orchestrate coding agents remotely")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)

                // Quick Actions
                VStack(spacing: 12) {
                    ActionButton(
                        title: "Add Remote Project",
                        subtitle: "Connect to a server via SSH",
                        icon: "globe.badge.chevron.backward",
                        color: .blue
                    ) {
                        appState.showingAddRemoteProject = true
                    }
                }
                .padding(.horizontal)

                // Recent Projects
                if !projects.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Recent Projects")
                            .font(.headline)
                            .padding(.horizontal)

                        ForEach(projects.prefix(5)) { project in
                            RecentProjectRow(project: project) {
                                appState.selectProject(project)
                            }
                        }
                    }
                }

                Spacer(minLength: 40)
            }
        }
        .navigationTitle("Home")
    }
}

// MARK: - Action Button

private struct ActionButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                    .frame(width: 44, height: 44)
                    .background(color.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Recent Project Row

private struct RecentProjectRow: View {
    let project: ProjectModel
    let action: () -> Void

    @EnvironmentObject private var appState: AppState

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ConnectionIndicator(
                    state: connectionState,
                    size: 10
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)

                    if let conn = project.sshConnection {
                        Text(conn.displayTarget)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(project.remotePath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(project.activeTasks.count) tasks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private var connectionState: ConnectionState {
        guard let id = project.connectionId else { return .disconnected }
        return appState.connectionState(for: id)
    }
}

// MARK: - Connection Indicator

struct ConnectionIndicator: View {
    let state: ConnectionState
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }

    private var color: Color {
        switch state {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .disconnected: .gray
        case .error: .red
        }
    }
}
