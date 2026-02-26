import SwiftUI
import SwiftData

/// App settings view.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @AppStorage("branchPrefix") private var branchPrefix = "emdash"
    @AppStorage("defaultShell") private var defaultShell = "/bin/bash"
    @AppStorage("autoApproveDefault") private var autoApproveDefault = true
    @AppStorage("terminalFontSize") private var terminalFontSize = 12.0

    @State private var showingClearDataConfirmation = false
    @State private var showingDisconnectAllConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    LabeledContent("Version", value: "1.0.0")
                }

                Section("Git") {
                    TextField("Branch Prefix", text: $branchPrefix)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Text("Worktree branches will be named: \(branchPrefix)/<task-name>-<hash>")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Agent Defaults") {
                    Toggle("Auto-approve by Default", isOn: $autoApproveDefault)

                    Picker("Default Shell", selection: $defaultShell) {
                        Text("/bin/bash").tag("/bin/bash")
                        Text("/bin/zsh").tag("/bin/zsh")
                        Text("/usr/bin/fish").tag("/usr/bin/fish")
                    }
                }

                Section("Terminal") {
                    HStack {
                        Text("Font Size")
                        Spacer()
                        Stepper(value: $terminalFontSize, in: 8...24, step: 1) {
                            Text("\(Int(terminalFontSize))pt")
                                .font(.callout.monospaced())
                        }
                    }
                }

                Section("SSH Connections") {
                    NavigationLink {
                        SSHConnectionListView()
                    } label: {
                        Label("Manage Connections", systemImage: "server.rack")
                    }

                    Button("Disconnect All") {
                        showingDisconnectAllConfirmation = true
                    }
                    .foregroundStyle(.orange)
                }

                Section("Running Agents") {
                    NavigationLink {
                        AgentStatusView()
                    } label: {
                        Label {
                            Text("Active Agents")
                        } icon: {
                            Image(systemName: "person.3")
                        }
                    }

                    let count = appState.agentManager.runningAgents.count
                    if count > 0 {
                        Text("\(count) agent(s) running")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Cache") {
                    Button("Clear Agent Detection Cache") {
                        appState.agentManager.invalidateAllDetectionCache()
                    }

                    Text("Agent detection results are cached for 5 minutes per connection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Data") {
                    Button("Clear All Data", role: .destructive) {
                        showingClearDataConfirmation = true
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Clear All Data?", isPresented: $showingClearDataConfirmation) {
                Button("Clear Everything", role: .destructive) {
                    clearAllData()
                }
            } message: {
                Text("This will delete all projects, tasks, conversations, and SSH connections. Keychain credentials will also be removed. This cannot be undone.")
            }
            .confirmationDialog("Disconnect All?", isPresented: $showingDisconnectAllConfirmation) {
                Button("Disconnect", role: .destructive) {
                    disconnectAll()
                }
            } message: {
                Text("This will close all SSH connections and stop monitoring.")
            }
        }
    }

    // MARK: - Actions

    private func clearAllData() {
        // Stop all agents and connections
        Task {
            await appState.sshService.disconnectAll()
        }
        appState.connectionMonitor.stopAll()
        appState.goHome()

        // Delete all model data
        do {
            try modelContext.delete(model: ChatMessage.self)
            try modelContext.delete(model: Conversation.self)
            try modelContext.delete(model: AgentTask.self)
            try modelContext.delete(model: ProjectModel.self)
            try modelContext.delete(model: SSHConnectionModel.self)
            try modelContext.save()
        } catch {
            Log.db.error("Failed to clear data: \(error.localizedDescription)")
        }

        // Clear caches
        appState.agentManager.invalidateAllDetectionCache()
        appState.detectedAgents.removeAll()
        appState.activeTerminals.removeAll()
        appState.connectionStates.removeAll()
        appState.saveActiveIds(projectId: nil, taskId: nil)

        Log.db.info("All data cleared")
    }

    private func disconnectAll() {
        appState.connectionMonitor.stopAll()
        Task {
            await appState.sshService.disconnectAll()
        }
        appState.connectionStates.removeAll()
    }
}
