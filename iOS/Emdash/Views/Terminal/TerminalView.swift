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
            // Terminal output area — each line is a separate Text in LazyVStack
            // so SwiftUI only renders visible lines (crucial for large output).
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(viewModel.lines.enumerated()), id: \.offset) { index, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: terminalFontSize, design: .monospaced))
                                .foregroundStyle(.green)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .id(index)
                        }
                    }
                }
                .onChange(of: viewModel.lines.count) {
                    proxy.scrollTo(viewModel.lines.count - 1, anchor: .bottom)
                }
                .onChange(of: viewModel.scrollToken) {
                    proxy.scrollTo(viewModel.lines.count - 1, anchor: .bottom)
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

/// View model managing terminal output as an array of lines for lazy rendering.
/// Loads past session output asynchronously on attach, auto-saves when sessions end.
/// Batches incoming output on a 50ms timer to avoid excessive SwiftUI re-renders.
@MainActor
final class TerminalViewModel: ObservableObject {
    /// Lines of terminal output — each line is rendered as a separate Text view
    /// inside LazyVStack so SwiftUI only measures/renders visible lines.
    @Published var lines: [String] = [""]
    /// Toggled to force a scroll when content changes without line count changing.
    @Published var scrollToken: Bool = false

    private var currentPtyId: String?
    private var currentConversationId: String?
    /// Tracks output from the current live session only (for saving).
    private var liveSessionOutput: String = ""
    private let maxLineCount = 10_000
    private weak var appState: AppState?

    /// Pending raw text to flush on next timer tick.
    private var pendingText: String = ""
    /// Timer that batches output updates (~50ms) to avoid per-chunk re-renders.
    private var flushTask: Task<Void, Never>?

    /// Regex for lines that are only box-drawing / separator characters (═─━┈ etc.)
    private static let separatorLinePattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: "^[\\s═─━┈┉┅╌╍┄╴╶╸╺│┃┊┋╎╏║╔╗╚╝╠╣╦╩╬├┤┬┴┼]+$")
    }()

    func attach(ptyId: String, conversationId: String, appState: AppState) {
        guard !ptyId.isEmpty else {
            lines = ["No agent configured for this conversation."]
            return
        }
        currentPtyId = ptyId
        currentConversationId = conversationId
        self.appState = appState
        lines = [""]
        liveSessionOutput = ""
        pendingText = ""

        // Load history asynchronously so navigation is instant
        Task {
            await loadHistory(conversationId: conversationId, appState: appState)
        }

        // Get the PTY session with retry — the session may still be initializing
        // when the view appears (race between spawnAgent and onAppear).
        Task {
            let session = await getSessionWithRetry(ptyId: ptyId, appState: appState)
            guard let session else {
                if lines == [""] {
                    lines = ["No active session for this agent."]
                }
                return
            }

            session.onOutput = { [weak self] data in
                guard let self else { return }
                guard let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in
                    self.liveSessionOutput += text
                    self.scheduleFlush(text)
                }
            }

            session.onExit = { [weak self] in
                Task { @MainActor in
                    self?.flushPending()
                    self?.appendLines("\n--- Session ended ---\n")
                    self?.autoSaveOutput()
                }
            }
        }
    }

    // MARK: - Batched Output

    /// Queue text and start a 50ms flush timer if one isn't running.
    private func scheduleFlush(_ text: String) {
        pendingText += text
        guard flushTask == nil else { return }
        flushTask = Task {
            try? await Task.sleep(for: .milliseconds(50))
            self.flushPending()
        }
    }

    /// Flush all pending text into the lines array in one update.
    private func flushPending() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingText.isEmpty else { return }
        let text = pendingText
        pendingText = ""
        appendLines(text)
    }

    /// Append text to the lines array, stripping ANSI codes and collapsing junk.
    private func appendLines(_ text: String) {
        // Strip all ANSI escape sequences (cursor movement, colors, erase, etc.)
        let cleaned = ANSIStripper.strip(text)
        let newParts = cleaned.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !newParts.isEmpty else { return }

        // Append first part to the current (last) line
        lines[lines.count - 1] += newParts[0]

        // Remaining parts are new lines — skip consecutive blank/separator lines
        if newParts.count > 1 {
            for part in newParts.dropFirst() {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                let isSeparator = !trimmed.isEmpty && Self.isSeparatorLine(trimmed)
                let isBlank = trimmed.isEmpty

                // Collapse consecutive blank/separator lines into one blank line
                if (isBlank || isSeparator), let lastLine = lines.last {
                    let lastTrimmed = lastLine.trimmingCharacters(in: .whitespaces)
                    if lastTrimmed.isEmpty {
                        continue // skip consecutive blank/separator
                    }
                }
                lines.append(isBlank ? "" : (isSeparator ? "" : part))
            }
        }

        // Trim if too many lines (keep most recent)
        if lines.count > maxLineCount {
            lines.removeFirst(lines.count - maxLineCount)
        }

        scrollToken.toggle()
    }

    /// Check if a line consists only of box-drawing / separator characters.
    private static func isSeparatorLine(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return separatorLinePattern.firstMatch(in: line, range: range) != nil
    }

    // MARK: - History

    /// Load past ChatMessage records asynchronously for this conversation.
    private func loadHistory(conversationId: String, appState: AppState) async {
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

        // Strip ANSI from saved history (old sessions may contain escape codes),
        // split into lines and assign
        let cleanHistory = ANSIStripper.strip(history)
        lines = cleanHistory.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.isEmpty { lines = [""] }

        Log.db.debug("Loaded \(messages.count) history message(s) for conversation \(conversationId)")
    }

    // MARK: - Persistence

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

    // MARK: - Session Lookup

    /// Retry session lookup to handle timing between agent spawn and view attach.
    private func getSessionWithRetry(ptyId: String, appState: AppState) async -> RemotePtySession? {
        if let session = await appState.agentManager.getSession(ptyId) {
            return session
        }
        for delay in [300, 700, 1500] {
            try? await Task.sleep(for: .milliseconds(delay))
            guard currentPtyId == ptyId else { return nil }
            if let session = await appState.agentManager.getSession(ptyId) {
                return session
            }
        }
        return nil
    }

    func detach() {
        flushPending()
        if !liveSessionOutput.isEmpty {
            autoSaveOutput()
        }
        currentPtyId = nil
        currentConversationId = nil
        appState = nil
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
