import SwiftUI
import SwiftData

/// List of saved SSH connections with management options.
struct SSHConnectionListView: View {
    @Query(sort: \SSHConnectionModel.name) private var connections: [SSHConnectionModel]
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext

    @State private var showingAddConnection = false

    var body: some View {
        List {
            if connections.isEmpty {
                ContentUnavailableView {
                    Label("No Connections", systemImage: "server.rack")
                } description: {
                    Text("Add an SSH connection to get started")
                } actions: {
                    Button("Add Connection") {
                        showingAddConnection = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ForEach(connections) { conn in
                    SSHConnectionRow(connection: conn)
                }
                .onDelete(perform: deleteConnections)
            }
        }
        .navigationTitle("SSH Connections")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddConnection = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddConnection) {
            AddSSHConnectionView()
        }
    }

    private func deleteConnections(at offsets: IndexSet) {
        for index in offsets {
            let conn = connections[index]
            appState.keychainService.deleteAllCredentials(connectionId: conn.id)
            Task {
                await appState.sshService.disconnect(connectionId: conn.id)
            }
            modelContext.delete(conn)
        }
        try? modelContext.save()
    }
}

private struct SSHConnectionRow: View {
    let connection: SSHConnectionModel
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            ConnectionIndicator(
                state: appState.connectionState(for: connection.id),
                size: 10
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name)
                    .font(.body.weight(.medium))

                Text(connection.displayTarget)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    Image(systemName: authIcon)
                        .font(.caption2)
                    Text(connection.authType.rawValue.capitalized)
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)
            }

            Spacer()

            connectionButton
        }
        .padding(.vertical, 4)
    }

    private var authIcon: String {
        switch connection.authType {
        case .password: "key.fill"
        case .key: "lock.shield"
        case .agent: "person.badge.key"
        }
    }

    @ViewBuilder
    private var connectionButton: some View {
        let state = appState.connectionState(for: connection.id)
        switch state {
        case .connected:
            Button("Disconnect") {
                Task { await appState.sshService.disconnect(connectionId: connection.id) }
                appState.updateConnectionState(connection.id, state: .disconnected)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)

        case .connecting, .reconnecting:
            ProgressView()
                .scaleEffect(0.7)

        case .disconnected, .error:
            Button("Connect") {
                Task { await connect() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func connect() async {
        appState.updateConnectionState(connection.id, state: .connecting)
        do {
            let password = appState.keychainService.getPassword(connectionId: connection.id)
            let passphrase = appState.keychainService.getPassphrase(connectionId: connection.id)

            _ = try await appState.sshService.connect(
                connectionId: connection.id,
                host: connection.host,
                port: connection.port,
                username: connection.username,
                authType: connection.authType,
                privateKeyPath: connection.privateKeyPath,
                password: password,
                passphrase: passphrase
            )
            appState.updateConnectionState(connection.id, state: .connected)
        } catch {
            appState.updateConnectionState(connection.id, state: .error)
        }
    }
}
