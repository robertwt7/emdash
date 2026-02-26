import SwiftUI
import SwiftData

/// Task detail view with conversation tabs and terminal.
/// Mirrors Electron's ChatInterface / MultiAgentTask view.
struct TaskDetailView: View {
    let task: AgentTask
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var selectedConversation: Conversation?
    @State private var showingAddAgent = false
    @State private var inputText = ""
    @State private var showingTaskActions = false
    @State private var isSendingFollowUp = false
    @State private var resumeError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Resume banner for stopped tasks
            if task.status == .idle || task.status == .completed || task.status == .failed {
                resumeBanner
            }

            // Conversation tabs
            if conversations.count > 1 {
                conversationTabs
            }

            // Agent working indicator
            if task.isRunning {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Agent is working...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.blue.opacity(0.06))
            }

            // Main terminal / chat area
            if let conversation = activeConversation {
                let ptyId = makePtyId(for: conversation)
                TerminalView(
                    ptyId: ptyId,
                    conversationId: conversation.id,
                    onInput: { text in
                        Task {
                            try? await appState.agentManager.sendInput(ptyId: ptyId, text: text)
                        }
                    }
                )
            } else {
                ContentUnavailableView(
                    "No Active Agent",
                    systemImage: "terminal",
                    description: Text("Start an agent to see its output here")
                )
            }

            // Input bar
            inputBar
        }
        .navigationTitle(task.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingAddAgent = true
                } label: {
                    Image(systemName: "person.badge.plus")
                }

                Menu {
                    if task.isRunning {
                        Button {
                            Task { await stopAllAgents() }
                        } label: {
                            Label("Stop All Agents", systemImage: "stop.circle")
                        }
                    }

                    Divider()

                    Button("Archive Task", systemImage: "archivebox") {
                        archiveTask()
                    }

                    Button("Delete Task", systemImage: "trash", role: .destructive) {
                        showingTaskActions = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingAddAgent) {
            AddAgentSheet(task: task)
        }
        .confirmationDialog("Delete Task?", isPresented: $showingTaskActions) {
            Button("Delete", role: .destructive) {
                Task { await deleteTask() }
            }
        } message: {
            Text("This will stop all agents and remove the remote worktree.")
        }
        .onAppear {
            selectedConversation = task.mainConversation
        }
    }

    // MARK: - Status Banner

    private var resumeBanner: some View {
        HStack {
            Image(systemName: task.status == .failed ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(task.status == .failed ? .red : .green)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.status == .failed ? "Agent failed" : "Agent finished")
                    .font(.callout.weight(.medium))
                Text("Send a message below to continue")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = resumeError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(task.status == .failed ? .red.opacity(0.06) : .green.opacity(0.06))
    }

    // MARK: - Conversation Tabs

    private var conversations: [Conversation] {
        task.sortedConversations
    }

    private var activeConversation: Conversation? {
        selectedConversation ?? conversations.first
    }

    private var conversationTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(conversations) { conv in
                    ConversationTab(
                        conversation: conv,
                        isSelected: activeConversation?.id == conv.id
                    ) {
                        selectedConversation = conv
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    // MARK: - Input Bar

    private var isAgentRunning: Bool {
        task.isRunning
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(
                isAgentRunning ? "Type a message..." : "Send a prompt to resume...",
                text: $inputText,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .padding(8)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .disabled(isSendingFollowUp)
            .onSubmit {
                sendToAgent()
            }

            if isSendingFollowUp {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Button {
                    sendToAgent()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(inputText.isEmpty ? .gray : .blue)
                }
                .disabled(inputText.isEmpty)
            }
        }
        .padding(8)
        .background(.bar)
    }

    // MARK: - Helpers

    private func makePtyId(for conversation: Conversation) -> String {
        guard let pid = conversation.providerId,
              let providerId = ProviderId(rawValue: pid)
        else { return "" }

        let kind: PtyIdHelper.Kind = conversation.isMain ? .main : .chat
        let suffix = conversation.isMain ? task.id : conversation.id
        return PtyIdHelper.make(providerId: providerId, kind: kind, suffix: suffix)
    }

    /// Send input to the agent — either directly to the running PTY session,
    /// or resume a stopped agent with this as a new prompt.
    private func sendToAgent() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""

        if isAgentRunning {
            // Agent is running — write directly to PTY stdin
            let ptyId = activeConversation.map { makePtyId(for: $0) } ?? ""
            Task {
                do {
                    try await appState.agentManager.sendInput(ptyId: ptyId, text: text + "\n")
                } catch {
                    resumeError = "Send failed: \(error.localizedDescription)"
                }
            }
        } else {
            // Agent has stopped — resume with this as a new prompt
            isSendingFollowUp = true
            Task {
                do {
                    try await appState.agentManager.resumeTask(
                        task: task,
                        followUpPrompt: text,
                        modelContext: modelContext
                    )
                } catch {
                    resumeError = error.localizedDescription
                }
                isSendingFollowUp = false
            }
        }
    }

    private func stopAllAgents() async {
        await appState.agentManager.stopAllAgents(taskId: task.id)
        task.status = .idle
    }

    private func archiveTask() {
        task.archivedAt = Date()
        task.status = .archived
        Task {
            await appState.agentManager.stopAllAgents(taskId: task.id)
        }
        appState.activeTask = nil
    }

    private func deleteTask() async {
        do {
            try await appState.agentManager.teardownTask(task: task, modelContext: modelContext)
            appState.activeTask = nil
        } catch {
            Log.agent.error("Delete task failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Conversation Tab

private struct ConversationTab: View {
    let conversation: Conversation
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if let provider = conversation.provider {
                    Image(systemName: provider.icon ?? "terminal")
                        .font(.caption2)
                }
                Text(conversation.title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Add Agent Sheet

private struct AddAgentSheet: View {
    let task: AgentTask
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProvider: ProviderId = .claude
    @State private var prompt = ""
    @State private var autoApprove = true
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent") {
                    Picker("Agent", selection: $selectedProvider) {
                        ForEach(availableProviders, id: \.self) { pid in
                            if let p = ProviderRegistry.provider(for: pid) {
                                Label(p.name, systemImage: p.icon ?? "terminal")
                                    .tag(pid)
                            }
                        }
                    }
                    Toggle("Auto-approve", isOn: $autoApprove)
                }

                Section("Prompt") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 60)
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .navigationTitle("Add Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task { await addAgent() }
                    }
                    .disabled(isCreating)
                }
            }
        }
    }

    private var availableProviders: [ProviderId] {
        guard let connId = task.project?.connectionId else { return ProviderId.allCases }
        return appState.detectedAgents[connId] ?? ProviderId.allCases
    }

    private func addAgent() async {
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        do {
            _ = try await appState.agentManager.addConversation(
                task: task,
                providerId: selectedProvider,
                initialPrompt: prompt.isEmpty ? nil : prompt,
                autoApprove: autoApprove,
                modelContext: modelContext
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
