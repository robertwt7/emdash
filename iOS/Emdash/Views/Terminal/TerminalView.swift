import SwiftUI
import SwiftData

/// Terminal view that displays agent output and accepts input.
/// Uses a monospaced text view for terminal rendering.
/// TODO: Replace with SwiftTerm UIViewRepresentable for full VT100 emulation.
struct TerminalView: View {
    let ptyId: String
    let conversationId: String
    let onInput: (String) -> Void

    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = TerminalViewModel()
    @AppStorage("terminalFontSize") private var terminalFontSize = 12.0

    var body: some View {
        VStack(spacing: 0) {
            // Terminal output area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Text(viewModel.output)
                            .font(.system(size: terminalFontSize, design: .monospaced))
                            .foregroundStyle(.green)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .id("terminal-bottom")
                    }
                }
                .onChange(of: viewModel.output) {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("terminal-bottom", anchor: .bottom)
                    }
                }
            }
            // Always dark background regardless of system appearance
            .background(Color.black)
            .colorScheme(.dark)

            // Keyboard toolbar for common terminal keys
            TerminalKeyboardToolbar(onKey: { key in
                onInput(key)
            })
        }
        .onAppear {
            viewModel.attach(ptyId: ptyId, conversationId: conversationId, appState: appState)
        }
        .onDisappear {
            viewModel.detach()
        }
        .onChange(of: ptyId) {
            viewModel.detach()
            viewModel.attach(ptyId: ptyId, conversationId: conversationId, appState: appState)
        }
    }
}

// MARK: - Terminal Keyboard Toolbar

/// Custom keyboard toolbar with terminal-specific keys (Ctrl+C, Tab, arrows, Esc).
/// These keys are hard to type on the iOS software keyboard.
struct TerminalKeyboardToolbar: View {
    let onKey: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                TerminalKey(label: "Esc", key: "\u{1B}", onKey: onKey)
                TerminalKey(label: "Tab", key: "\t", onKey: onKey)
                Divider().frame(height: 20)
                TerminalKey(label: "Ctrl+C", key: "\u{03}", onKey: onKey)
                TerminalKey(label: "Ctrl+D", key: "\u{04}", onKey: onKey)
                TerminalKey(label: "Ctrl+Z", key: "\u{1A}", onKey: onKey)
                TerminalKey(label: "Ctrl+L", key: "\u{0C}", onKey: onKey)
                Divider().frame(height: 20)
                TerminalKey(label: "\u{2191}", key: "\u{1B}[A", onKey: onKey) // Up arrow
                TerminalKey(label: "\u{2193}", key: "\u{1B}[B", onKey: onKey) // Down arrow
                TerminalKey(label: "\u{2190}", key: "\u{1B}[D", onKey: onKey) // Left arrow
                TerminalKey(label: "\u{2192}", key: "\u{1B}[C", onKey: onKey) // Right arrow
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(.ultraThinMaterial)
    }
}

private struct TerminalKey: View {
    let label: String
    let key: String
    let onKey: (String) -> Void

    var body: some View {
        Button {
            onKey(key)
        } label: {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Terminal View Model

/// View model managing terminal output buffer with ChatMessage persistence.
/// Loads past session output on attach, auto-saves output when sessions end.
@MainActor
final class TerminalViewModel: ObservableObject {
    @Published var output: String = ""

    private var currentPtyId: String?
    private var currentConversationId: String?
    /// Tracks output from the current live session only (for saving).
    private var liveSessionOutput: String = ""
    private let maxOutputLength = 100_000
    private weak var appState: AppState?

    func attach(ptyId: String, conversationId: String, appState: AppState) {
        guard !ptyId.isEmpty else {
            output = "No agent configured for this conversation.\n"
            return
        }
        currentPtyId = ptyId
        currentConversationId = conversationId
        self.appState = appState
        output = ""
        liveSessionOutput = ""

        // Load saved terminal history from previous sessions
        loadHistory(conversationId: conversationId, appState: appState)

        // Get the PTY session with retry — the session may still be initializing
        // when the view appears (race between spawnAgent and onAppear).
        Task {
            let session = await getSessionWithRetry(ptyId: ptyId, appState: appState)
            guard let session else {
                // No live session — history was already loaded above
                if output.isEmpty {
                    output = "No active session for this agent.\n"
                }
                return
            }

            session.onOutput = { [weak self] data in
                guard let self else { return }
                guard let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in
                    self.appendOutput(text)
                    self.liveSessionOutput += text
                }
            }

            session.onExit = { [weak self] in
                Task { @MainActor in
                    self?.appendOutput("\n--- Session ended ---\n")
                    self?.autoSaveOutput()
                }
            }
        }
    }

    /// Load past ChatMessage records (terminal output + user messages) for this conversation.
    private func loadHistory(conversationId: String, appState: AppState) {
        guard let context = appState.modelContainer?.mainContext else { return }

        let targetId = conversationId
        let terminalSender = "terminal"
        let userSender = "user"
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate<ChatMessage> { msg in
                msg.conversation?.id == targetId &&
                (msg.sender == terminalSender || msg.sender == userSender)
            },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )

        guard let messages = try? context.fetch(descriptor), !messages.isEmpty else { return }

        // Interleave terminal output and user messages chronologically.
        // Terminal output gets a "--- Session ended ---" suffix.
        // User messages get a "> " prefix to distinguish prompts from output.
        var history = ""
        for message in messages {
            if message.sender == "user" {
                history += "\n> \(message.content)\n\n"
            } else {
                history += message.content
                if !message.content.hasSuffix("\n") {
                    history += "\n"
                }
                history += "--- Session ended ---\n"
            }
        }
        history += "\n"
        output = history

        Log.db.debug("Loaded \(messages.count) history message(s) for conversation \(conversationId)")
    }

    /// Auto-save current live session output when the session ends.
    private func autoSaveOutput() {
        guard !liveSessionOutput.isEmpty,
              let conversationId = currentConversationId,
              let context = appState?.modelContainer?.mainContext
        else { return }

        let targetId = conversationId
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { conv in
                conv.id == targetId
            }
        )

        guard let conversation = try? context.fetch(descriptor).first else {
            Log.db.warning("Cannot save terminal output: conversation \(conversationId) not found")
            return
        }

        let message = ChatMessage(
            content: liveSessionOutput,
            sender: "terminal",
            conversation: conversation
        )
        context.insert(message)
        try? context.save()
        liveSessionOutput = ""

        Log.db.debug("Auto-saved terminal output (\(message.content.count) chars) for conversation \(conversationId)")
    }

    /// Retry session lookup to handle timing between agent spawn and view attach.
    private func getSessionWithRetry(ptyId: String, appState: AppState) async -> RemotePtySession? {
        // Try immediately
        if let session = await appState.agentManager.getSession(ptyId) {
            return session
        }
        // Retry after short delays
        for delay in [300, 700, 1500] {
            try? await Task.sleep(for: .milliseconds(delay))
            guard currentPtyId == ptyId else { return nil } // view changed
            if let session = await appState.agentManager.getSession(ptyId) {
                return session
            }
        }
        return nil
    }

    func detach() {
        // Save any unsaved live output before detaching
        if !liveSessionOutput.isEmpty {
            autoSaveOutput()
        }
        currentPtyId = nil
        currentConversationId = nil
        appState = nil
    }

    private func appendOutput(_ text: String) {
        output += text
        // Trim if too long (keep most recent content)
        if output.count > maxOutputLength {
            let startIndex = output.index(output.endIndex, offsetBy: -maxOutputLength)
            output = String(output[startIndex...])
        }
    }
}

// MARK: - Terminal Pane (for split view detail)

/// Wrapper for terminal in the right sidebar / detail column.
struct TaskTerminalPane: View {
    let task: AgentTask
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "terminal")
                Text(task.name)
                    .font(.callout.weight(.medium))
                Spacer()

                if let agentId = task.agentId,
                   let pid = ProviderId(rawValue: agentId),
                   let provider = ProviderRegistry.provider(for: pid)
                {
                    Text(provider.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // Conversation terminals
            if let conversations = task.conversations, conversations.count > 1 {
                TabView {
                    ForEach(task.sortedConversations) { conv in
                        terminalForConversation(conv)
                            .tabItem {
                                Label(
                                    conv.title,
                                    systemImage: conv.provider?.icon ?? "terminal"
                                )
                            }
                    }
                }
            } else if let mainConv = task.mainConversation {
                terminalForConversation(mainConv)
            } else {
                ContentUnavailableView(
                    "No Terminal",
                    systemImage: "terminal",
                    description: Text("No agent session active")
                )
            }
        }
    }

    private func terminalForConversation(_ conversation: Conversation) -> some View {
        let ptyId = makePtyId(for: conversation)
        return TerminalView(
            ptyId: ptyId,
            conversationId: conversation.id,
            onInput: { text in
                Task {
                    try? await appState.agentManager.sendInput(ptyId: ptyId, text: text)
                }
            }
        )
    }

    private func makePtyId(for conversation: Conversation) -> String {
        guard let pid = conversation.providerId,
              let providerId = ProviderId(rawValue: pid)
        else { return "" }

        let kind: PtyIdHelper.Kind = conversation.isMain ? .main : .chat
        let suffix = conversation.isMain ? task.id : conversation.id
        return PtyIdHelper.make(providerId: providerId, kind: kind, suffix: suffix)
    }
}
