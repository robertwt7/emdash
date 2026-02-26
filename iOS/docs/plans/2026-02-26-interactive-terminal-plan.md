# Interactive Terminal via Citadel `withPTY` — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the one-shot `executeCommandStream` SSH pattern with Citadel's `withPTY` for persistent, bidirectional terminal I/O.

**Architecture:** `SSHService.startInteractiveShell()` opens a long-lived PTY session via `client.withPTY()`. A detached `Task` runs the closure; a `CheckedContinuation` bridges the `TTYStdinWriter` back to the caller. The existing `SSHShellSession` class gets real write/resize backed by the writer. `RemotePtyService` writes init commands as stdin lines instead of baking them into the shell open call. `TaskDetailView` sends input directly to the live session instead of recreating sessions.

**Tech Stack:** Swift, Citadel 0.12.0 (`withPTY`, `TTYStdinWriter`, `TTYOutput`), SwiftNIO (`ByteBuffer`), SwiftUI, SwiftData

**Design doc:** `iOS/docs/plans/2026-02-26-interactive-terminal-design.md`

---

## Task 1: Bump Deployment Target to iOS 18

**Files:**
- Modify: `iOS/project.yml:5` and `:31`
- Modify: `iOS/Package.swift:6`
- Modify: `iOS/AGENTS.md:7` and `:21`

**Step 1: Update project.yml**

Change both deployment target entries from `"17.0"` to `"18.0"`:

```yaml
# Line 5
  deploymentTarget:
    iOS: "18.0"

# Line 31
        IPHONEOS_DEPLOYMENT_TARGET: "18.0"
```

**Step 2: Update Package.swift**

```swift
platforms: [.iOS(.v18)],
```

**Step 3: Update AGENTS.md references**

Change `iOS 17+` to `iOS 18+` in the tech stack and quickstart sections.

**Step 4: Commit**

```bash
git add iOS/project.yml iOS/Package.swift iOS/AGENTS.md
git commit -m "chore(ios): bump deployment target to iOS 18 for Citadel withPTY"
```

---

## Task 2: Rewrite `SSHShellSession` for Interactive PTY

This is the core change. Replace the closure-based `SSHShellSession` with one backed by `TTYStdinWriter`.

**Files:**
- Modify: `iOS/Emdash/Services/SSHService.swift`

**Step 1: Add NIOSSH import and rewrite `SSHShellSession`**

At the top of `SSHService.swift`, add:

```swift
import NIOSSH
```

Replace the entire `SSHShellSession` class (lines 294-357) with:

```swift
/// Wraps an interactive SSH PTY channel for terminal I/O.
/// Backed by Citadel's withPTY: TTYStdinWriter for writes, TTYOutput for reads.
class SSHShellSession: @unchecked Sendable {
    let connectionId: String

    var onData: ((Data) -> Void)?
    var onClose: (() -> Void)?

    /// The PTY stdin writer — set once the withPTY closure starts.
    private var writer: TTYStdinWriter?
    /// The long-lived Task running the withPTY closure.
    private var ptyTask: Task<Void, Never>?
    /// Signals that the writer is ready.
    private var writerContinuation: CheckedContinuation<Void, Never>?

    init(connectionId: String) {
        self.connectionId = connectionId
    }

    /// Called by SSHService to provide the writer once withPTY starts.
    func setWriter(_ writer: TTYStdinWriter) {
        self.writer = writer
        writerContinuation?.resume()
        writerContinuation = nil
    }

    /// Called by SSHService to set the background PTY task for cancellation.
    func setPtyTask(_ task: Task<Void, Never>) {
        self.ptyTask = task
    }

    /// Wait until the writer is available (withPTY closure has started).
    func waitForWriter() async {
        if writer != nil { return }
        await withCheckedContinuation { continuation in
            if writer != nil {
                continuation.resume()
            } else {
                writerContinuation = continuation
            }
        }
    }

    /// Start draining the TTYOutput inbound stream and forwarding to onData.
    func startReading(inbound: TTYOutput) {
        Task { [weak self] in
            do {
                for try await chunk in inbound {
                    let buf: ByteBuffer
                    switch chunk {
                    case .stdout(let b): buf = b
                    case .stderr(let b): buf = b
                    }
                    if let data = buf.getData(at: buf.readerIndex, length: buf.readableBytes),
                       !data.isEmpty
                    {
                        await MainActor.run {
                            self?.onData?(data)
                        }
                    }
                }
            } catch {
                Log.pty.error("PTY read error: \(error.localizedDescription)")
            }
            // Stream ended — agent exited or connection dropped
            await MainActor.run {
                self?.onClose?()
            }
        }
    }

    /// Write data to the PTY stdin.
    func write(_ data: Data) async throws {
        guard let writer else {
            Log.pty.warning("Write called before PTY writer is ready (\(data.count) bytes)")
            return
        }
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await writer.write(buffer)
    }

    /// Write a string to the PTY stdin.
    func write(_ string: String) async throws {
        try await write(Data(string.utf8))
    }

    /// Resize the remote terminal.
    func resize(cols: Int, rows: Int) async throws {
        guard let writer else { return }
        try await writer.changeSize(
            cols: cols, rows: rows,
            pixelWidth: 0, pixelHeight: 0
        )
    }

    /// Close the PTY session.
    func close() async {
        ptyTask?.cancel()
        ptyTask = nil
        writer = nil
    }
}
```

**Step 2: Replace `startShell()` with `startInteractiveShell()`**

Replace the existing `startShell` method (lines 189-242) with:

```swift
/// Start an interactive PTY shell session.
/// Uses Citadel's withPTY for full bidirectional I/O (stdin write + stdout stream + resize).
/// The withPTY closure runs in a detached Task for the session's lifetime.
func startInteractiveShell(
    connectionId: String,
    cols: Int = 120,
    rows: Int = 40
) async throws -> SSHShellSession {
    guard let conn = connections[connectionId] else {
        throw SSHError.notConnected(connectionId)
    }

    connections[connectionId]?.lastActivity = Date()
    Log.ssh.info("Interactive PTY session starting for connection \(connectionId)")

    let session = SSHShellSession(connectionId: connectionId)

    let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
        wantReply: true,
        term: "xterm-256color",
        terminalCharacterWidth: cols,
        terminalRowHeight: rows,
        terminalPixelWidth: 0,
        terminalPixelHeight: 0,
        terminalModes: .init([])
    )

    // We need to capture the client reference for the detached task
    let client = conn.client

    // Use a continuation to wait until the writer is available
    // before returning the session to the caller.
    let ptyTask = Task<Void, Never> {
        do {
            try await client.withPTY(ptyRequest) { inbound, outbound in
                // Provide the writer to the session
                session.setWriter(outbound)
                // Start draining output
                session.startReading(inbound: inbound)
                // Keep the closure alive until the inbound stream ends.
                // When the agent exits, the for-await loop in startReading
                // finishes, but we need THIS closure to stay open for the
                // channel to remain active. Wait for cancellation or stream end.
                try await withTaskCancellationHandler {
                    // Wait indefinitely until cancelled or stream ends
                    try await Task.sleep(for: .seconds(86400 * 365)) // ~1 year
                } onCancel: {
                    // Task was cancelled (session.close() called)
                    Log.pty.debug("PTY closure cancelled for \(connectionId)")
                }
            }
        } catch is CancellationError {
            Log.pty.debug("PTY session cancelled for \(connectionId)")
        } catch {
            Log.pty.error("PTY session error for \(connectionId): \(error.localizedDescription)")
        }
        // Notify session ended
        await MainActor.run {
            session.onClose?()
        }
    }

    session.setPtyTask(ptyTask)

    // Wait for the writer to become available before returning
    await session.waitForWriter()

    Log.ssh.info("Interactive PTY session ready for connection \(connectionId)")
    return session
}
```

**Step 3: Remove the old `startShell()` method and its `dataStream`/`writeHandler` pattern entirely.**

Delete lines 185-242 (the old `startShell` method with its `executeCommandStream` + no-op write handler).

**Step 4: Update the comment at top of `SSHShellSession` section**

Remove the old comments about "Citadel 0.7.x limitation" and "Upgrade to Citadel 0.9+".

**Step 5: Commit**

```bash
git add iOS/Emdash/Services/SSHService.swift
git commit -m "feat(ios): replace executeCommandStream with withPTY for interactive SSH"
```

---

## Task 3: Update `RemotePtyService` to Write Init Commands as Stdin

**Files:**
- Modify: `iOS/Emdash/Services/RemotePtyService.swift`

**Step 1: Update `startSession()` to use interactive shell + stdin writes**

Replace the `startSession` method (lines 78-117) with:

```swift
/// Start a remote PTY session for an agent.
/// Opens an interactive PTY shell, then writes init commands (env, cd, agent CLI)
/// as stdin lines — replacing the old baked-command approach.
func startSession(options: StartOptions) async throws -> RemotePtySession {
    // Validate shell
    guard allowedShells.contains(options.shell) else {
        throw RemotePtyError.invalidShell(options.shell)
    }

    // Open an interactive PTY shell (no command baked in)
    let shellSession = try await sshService.startInteractiveShell(
        connectionId: options.connectionId,
        cols: options.cols,
        rows: options.rows
    )

    // Create our session wrapper
    let session = RemotePtySession(
        id: options.id,
        connectionId: options.connectionId,
        providerId: options.provider.id,
        shellSession: shellSession
    )

    sessions[options.id] = session

    // Write init commands as stdin lines to the live shell
    let initLines = buildRemoteInitKeystrokes(options: options)
    for line in initLines {
        try await shellSession.write(line + "\n")
    }

    // Keystroke injection for TUI agents is now possible with interactive PTY!
    if options.provider.useKeystrokeInjection, let prompt = options.initialPrompt, !prompt.isEmpty {
        // Wait briefly for the TUI to start up before injecting keystrokes
        try? await Task.sleep(for: .milliseconds(500))
        try await shellSession.write(prompt)
        try await shellSession.write("\n")
        Log.pty.info("Injected keystroke prompt for \(options.provider.name)")
    }

    Log.pty.info("Started remote PTY session: \(options.id) with \(options.provider.name)")
    return session
}
```

**Step 2: Update `buildRemoteInitKeystrokes` to return `[String]` instead of `String`**

Change return type and remove the `joined()` call. Also remove the comment about Citadel appending `\n;exit\n`:

```swift
/// Build remote init commands as individual lines.
/// Each line will be written to the interactive PTY shell's stdin.
private func buildRemoteInitKeystrokes(options: StartOptions) -> [String] {
    var lines: [String] = []

    // Prepend common version manager shim/bin paths, then source profiles.
    let extraPaths = [
        "$HOME/.local/share/mise/shims",
        "$HOME/.asdf/shims",
        "$HOME/.volta/bin",
        "$HOME/.local/bin",
        "$HOME/.npm-global/bin",
        "$HOME/.nvm/current/bin",
        "$HOME/.fnm/aliases/default/bin",
        "/usr/local/bin",
        "/home/linuxbrew/.linuxbrew/bin",
    ].joined(separator: ":")
    lines.append("export PATH=\"\(extraPaths):$PATH\"; . ~/.profile 2>/dev/null; . ~/.bashrc 2>/dev/null; . ~/.bash_profile 2>/dev/null")

    // Export environment variables
    for (key, value) in options.env {
        guard ShellEscape.isValidEnvVarName(key) else { continue }
        lines.append("export \(key)=\(ShellEscape.quoteShellArg(value))")
    }

    // Build the CLI command with detection.
    let cliCommand = buildCliCommand(options: options)
    if let cli = options.provider.effectiveCli {
        let installHint = options.provider.installCommand.map { " Install: \($0)" } ?? ""
        let errorMsg = "emdash: \(cli) not found on remote.\(installHint)"

        let agentCheck = "if command -v \(ShellEscape.quoteShellArg(cli)) >/dev/null 2>&1; then exec \(cliCommand); else printf '%s\\n' \(ShellEscape.quoteShellArg(errorMsg)); fi"
        lines.append("cd \(ShellEscape.quoteShellArg(options.cwd)) && \(agentCheck)")
    } else {
        lines.append("cd \(ShellEscape.quoteShellArg(options.cwd)) && \(cliCommand)")
    }

    return lines
}
```

**Step 3: Update `buildCliCommand` — remove the `-i` flag workaround**

The `-i` (interactive prompt) flag now works because we have a real PTY. Update the flag handling in `buildCliCommand` (around line 219-223):

```swift
if flag.isEmpty {
    // Positional argument (Claude Code, Codex, etc.)
    args.append(ShellEscape.quoteShellArg(prompt))
} else {
    // Flag-based (-i, --prompt, -c, -t, -p, etc.)
    // -i (--prompt-interactive) now works because we have a real PTY
    args.append(flag)
    args.append(ShellEscape.quoteShellArg(prompt))
}
```

**Step 4: Commit**

```bash
git add iOS/Emdash/Services/RemotePtyService.swift
git commit -m "feat(ios): write init commands as stdin lines to interactive PTY"
```

---

## Task 4: Update `TaskDetailView` — Direct Input to Live Session

**Files:**
- Modify: `iOS/Emdash/Views/Tasks/TaskDetailView.swift`

**Step 1: Replace `sendFollowUp()` with `sendToSession()`**

The input bar now has two modes:
- **Agent running**: write directly to the live PTY stdin
- **Agent stopped**: resume with a new session (keeps the existing `resumeTask` for starting fresh)

Replace the `sendFollowUp()` method and update `inputBar`:

```swift
// MARK: - Input

/// Send input text to the live agent session or resume a stopped agent.
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
```

**Step 2: Update the `inputBar` view**

Change placeholder text and enable input when agent is running:

```swift
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
```

**Step 3: Wire `onInput` on `TerminalView` to actually send to PTY**

Replace `onInput: { _ in }` with real input handling:

```swift
TerminalView(
    ptyId: ptyId,
    conversationId: conversation.id,
    onInput: { text in
        Task {
            try? await appState.agentManager.sendInput(ptyId: ptyId, text: text)
        }
    }
)
```

**Step 4: Remove the `sendFollowUp()` method and its comment about "one-shot constraint of Citadel 0.7.x".**

**Step 5: Remove `.id("\(ptyId)-\(appState.sessionGeneration)")` from TerminalView** — we no longer need to force recreation since the session is persistent.

**Step 6: Commit**

```bash
git add iOS/Emdash/Views/Tasks/TaskDetailView.swift
git commit -m "feat(ios): direct input to live PTY session from input bar and keyboard toolbar"
```

---

## Task 5: Clean Up — Remove Workarounds

**Files:**
- Modify: `iOS/Emdash/App/AppState.swift` — remove `sessionGeneration`
- Modify: `iOS/Emdash/Services/AgentManager.swift` — remove `sessionGeneration` bump, simplify `resumeTask`

**Step 1: Remove `sessionGeneration` from AppState**

Delete this line from `AppState`:
```swift
// Incremented when a new PTY session is created, so TerminalView can reattach
@Published var sessionGeneration: Int = 0
```

**Step 2: Remove `sessionGeneration` bump from `AgentManager.spawnAgent()`**

Delete from `spawnAgent()` (line 322):
```swift
// Bump session generation so TerminalView reattaches to the new session
appState.sessionGeneration += 1
```

**Step 3: Simplify `AgentManager.resumeTask()` — remove `followUpPrompt` parameter**

Since interactive input goes directly to the PTY, `resumeTask()` no longer needs a follow-up prompt. It only needs to resume a stopped agent with a fresh session:

```swift
/// Resume a stopped task's agent.
func resumeTask(
    task: AgentTask,
    followUpPrompt: String? = nil,
    modelContext: ModelContext
) async throws {
    // ... (keep existing worktree verification logic) ...

    let ptyId = PtyIdHelper.make(providerId: providerId, kind: .main, suffix: task.id)

    if runningAgents[ptyId] != nil {
        await stopAgent(ptyId: ptyId)
    }

    // When resuming without a specific prompt, use generic resume flags.
    // When a prompt is provided (e.g., from stopped-state input bar), pass it as initial prompt.
    let hasPrompt = followUpPrompt != nil
    try await spawnAgent(
        ptyId: ptyId,
        connectionId: connectionId,
        provider: provider,
        cwd: cwd,
        initialPrompt: followUpPrompt,
        autoApprove: true,
        env: [:],
        taskId: task.id,
        projectId: project.id,
        isResume: !hasPrompt
    )

    task.status = .running
    task.updatedAt = Date()
    try modelContext.save()
}
```

Note: We keep `followUpPrompt` on `resumeTask` because it's still used when resuming from the stopped state — the input bar sends the prompt which starts a new agent session with that prompt. The difference is that while the agent is *running*, input goes directly to stdin.

**Step 4: Commit**

```bash
git add iOS/Emdash/App/AppState.swift iOS/Emdash/Services/AgentManager.swift
git commit -m "refactor(ios): remove sessionGeneration workaround, clean up resume flow"
```

---

## Task 6: Update Documentation

**Files:**
- Modify: `iOS/CHANGELOG.md`
- Modify: `iOS/AGENTS.md` (data flow diagram)

**Step 1: Add Phase 2.5 to CHANGELOG.md**

Add a new section documenting the interactive terminal implementation.

**Step 2: Update AGENTS.md data flow diagram**

Update the data flow section to show direct stdin writes instead of "creates new SSH session":

```
User creates task
  -> AgentManager.createAndStartTask()
    -> RemoteGitService.createWorktree()       [SSH exec]
    -> RemotePtyService.startSession()          [SSH PTY channel]
      -> SSHService.startInteractiveShell()     [Citadel withPTY]
      -> writes init commands to PTY stdin:
           export ENV
           cd /path
           exec cli args
    -> TerminalView displays output via onData callback
    -> User input -> SSHShellSession.write()    [PTY stdin - interactive!]
```

**Step 3: Remove the TODO item about interactive terminal from CHANGELOG.md** since it's now implemented.

**Step 4: Commit**

```bash
git add iOS/CHANGELOG.md iOS/AGENTS.md
git commit -m "docs(ios): document interactive terminal implementation (Phase 2.5)"
```

---

## Execution Order

Tasks are sequential — each builds on the previous:

1. **Task 1** (deployment target) — prerequisite for `withPTY` availability
2. **Task 2** (SSHService rewrite) — core infrastructure
3. **Task 3** (RemotePtyService update) — uses new `startInteractiveShell()`
4. **Task 4** (TaskDetailView) — uses new write capabilities
5. **Task 5** (cleanup) — removes old workarounds
6. **Task 6** (docs) — documents everything

## Risk Notes

- **`withPTY` closure lifetime**: The closure must stay alive for the channel to remain open. The `Task.sleep(for: .seconds(86400 * 365))` pattern keeps it open. Cancellation via `session.close()` → `ptyTask.cancel()` tears it down cleanly.
- **Writer availability race**: `waitForWriter()` with `CheckedContinuation` ensures `startInteractiveShell()` doesn't return until the writer is ready. No writes can happen before the PTY is established.
- **Init command timing**: Writing init commands as stdin lines to an interactive shell means the shell prompt and startup output will be visible in the terminal. This is actually desirable — it looks like a real terminal.
