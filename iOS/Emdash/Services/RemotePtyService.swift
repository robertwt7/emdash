import Foundation

/// Manages remote PTY sessions for agent interaction over SSH.
/// Port of Electron's RemotePtyService + ptyIpc.ts remote spawn logic.
actor RemotePtyService {
    private let sshService: SSHService
    private let sessionMapService: SessionMapService
    private var sessions: [String: RemotePtySession] = [:]

    /// Allowed shell binaries for security (matches Electron's ALLOWED_SHELLS).
    private let allowedShells: Set<String> = [
        "/bin/bash", "/bin/sh", "/bin/zsh",
        "/usr/bin/bash", "/usr/bin/zsh", "/usr/bin/fish",
        "/usr/local/bin/bash", "/usr/local/bin/zsh", "/usr/local/bin/fish",
    ]

    /// Environment variables to forward to agents (subset of Electron's AGENT_ENV_VARS).
    static let agentEnvVars: [String] = [
        "AMP_API_KEY", "ANTHROPIC_API_KEY", "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_DEFAULT_REGION",
        "AZURE_OPENAI_API_KEY", "CODEBUFF_API_KEY", "COPILOT_CLI_TOKEN",
        "CURSOR_API_KEY", "DASHSCOPE_API_KEY", "GEMINI_API_KEY",
        "GH_TOKEN", "GITHUB_TOKEN", "GOOGLE_API_KEY",
        "KIMI_API_KEY", "MISTRAL_API_KEY", "MOONSHOT_API_KEY",
        "OPENAI_API_KEY", "OPENAI_BASE_URL",
    ]

    init(sshService: SSHService, sessionMapService: SessionMapService = SessionMapService()) {
        self.sshService = sshService
        self.sessionMapService = sessionMapService
    }

    // MARK: - Session Lifecycle

    struct StartOptions {
        let id: String // PTY ID: {providerId}-main-{taskId}
        let connectionId: String
        let cwd: String
        let provider: ProviderDefinition
        let shell: String
        let autoApprove: Bool
        let initialPrompt: String?
        let env: [String: String]
        let cols: Int
        let rows: Int
        let isResume: Bool

        init(
            id: String,
            connectionId: String,
            cwd: String,
            provider: ProviderDefinition,
            shell: String = "/bin/bash",
            autoApprove: Bool = true,
            initialPrompt: String? = nil,
            env: [String: String] = [:],
            cols: Int = 120,
            rows: Int = 40,
            isResume: Bool = false
        ) {
            self.id = id
            self.connectionId = connectionId
            self.cwd = cwd
            self.provider = provider
            self.shell = shell
            self.autoApprove = autoApprove
            self.initialPrompt = initialPrompt
            self.env = env
            self.cols = cols
            self.rows = rows
            self.isResume = isResume
        }
    }

    /// Start a remote PTY session for an agent.
    /// Opens an interactive PTY shell, then writes init commands (env, cd, agent CLI)
    /// as stdin lines — enabling full bidirectional I/O.
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

        // Keystroke injection for TUI agents (amp, opencode) is now possible
        // with interactive PTY — type the prompt into the TUI after startup.
        if options.provider.useKeystrokeInjection, let prompt = options.initialPrompt, !prompt.isEmpty {
            try? await Task.sleep(for: .milliseconds(500))
            try await shellSession.write(prompt)
            try await shellSession.write("\n")
            Log.pty.info("Injected keystroke prompt for \(options.provider.name)")
        }

        Log.pty.info("Started remote PTY session: \(options.id) with \(options.provider.name)")
        return session
    }

    /// Build remote init commands as individual lines.
    /// Each line will be written to the interactive PTY shell's stdin.
    private func buildRemoteInitKeystrokes(options: StartOptions) -> [String] {
        var lines: [String] = []

        // Prepend common version manager shim/bin paths, then source profiles.
        // Even with a PTY, the login shell may not source all profiles depending
        // on the remote's shell configuration. Adding paths explicitly ensures
        // the agent binary is found via version managers (mise, asdf, volta, etc.).
        let extraPaths = [
            "$HOME/.local/share/mise/shims",   // mise (formerly rtx)
            "$HOME/.asdf/shims",               // asdf
            "$HOME/.volta/bin",                 // volta
            "$HOME/.local/bin",                 // pipx, user-local installs
            "$HOME/.npm-global/bin",            // npm global (custom prefix)
            "$HOME/.nvm/current/bin",           // nvm (if 'current' symlink exists)
            "$HOME/.fnm/aliases/default/bin",   // fnm
            "/usr/local/bin",                   // homebrew (macOS), manual installs
            "/home/linuxbrew/.linuxbrew/bin",   // homebrew (Linux)
        ].joined(separator: ":")
        lines.append("export PATH=\"\(extraPaths):$PATH\"; . ~/.profile 2>/dev/null; . ~/.bashrc 2>/dev/null; . ~/.bash_profile 2>/dev/null")

        // Export environment variables
        for (key, value) in options.env {
            guard ShellEscape.isValidEnvVarName(key) else { continue }
            lines.append("export \(key)=\(ShellEscape.quoteShellArg(value))")
        }

        // Build the CLI command with detection.
        // cd && if/fi ensures agent only starts if the worktree directory exists.
        // exec replaces the shell with the agent process for a clean process tree.
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

    /// Build the CLI agent command with all flags, session isolation, and resume support.
    private func buildCliCommand(options: StartOptions) -> String {
        let provider = options.provider
        var args: [String] = []

        // CLI binary or auto-start command
        if let autoStart = provider.autoStartCommand {
            args.append(autoStart)
        } else if let cli = provider.cli {
            args.append(cli)
        } else {
            return "echo 'No CLI configured for \(provider.name)'"
        }

        // Default args (e.g., goose: ["run", "-s"])
        args.append(contentsOf: provider.defaultArgs)

        // Auto-approve flag
        if options.autoApprove, let flag = provider.autoApproveFlag {
            args.append(flag)
        }

        // Session isolation (Claude only — deterministic session UUIDs)
        let sessionArgs = sessionMapService.applySessionIsolation(
            provider: provider,
            ptyId: options.id,
            cwd: options.cwd,
            isResume: options.isResume
        )

        if let sessionArgs {
            // Session isolation handled resume
            args.append(contentsOf: sessionArgs)
        } else if options.isResume, let resumeFlag = provider.resumeFlag {
            // Generic resume (no session isolation, or isolation returned nil)
            for part in resumeFlag.components(separatedBy: " ") {
                args.append(part)
            }
        }

        // Initial prompt (if passed via flag, not keystroke injection).
        // Prompt is allowed alongside resume flags — matches Electron's buildProviderCliArgs
        // which does NOT exclude prompt when resuming. This enables follow-up messages:
        // e.g., `claude --resume <uuid> "follow-up message"`
        if let prompt = options.initialPrompt, !prompt.isEmpty,
           let flag = provider.initialPromptFlag, !provider.useKeystrokeInjection
        {
            if flag.isEmpty {
                // Positional argument (Claude Code, Codex, etc.)
                args.append(ShellEscape.quoteShellArg(prompt))
            } else {
                // Flag-based (-i, --prompt, -c, -t, -p, etc.)
                // -i (--prompt-interactive) now works with interactive PTY
                args.append(flag)
                args.append(ShellEscape.quoteShellArg(prompt))
            }
        }

        return args.joined(separator: " ")
    }

    /// Stop a session and clean up.
    func stopSession(_ id: String) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        await session.close()
        Log.pty.info("Stopped remote PTY session: \(id)")
    }

    /// Write to a session's stdin.
    func write(sessionId: String, data: Data) async throws {
        guard let session = sessions[sessionId] else {
            throw RemotePtyError.sessionNotFound(sessionId)
        }
        try await session.shellSession.write(data)
    }

    /// Write a string to a session.
    func write(sessionId: String, text: String) async throws {
        try await write(sessionId: sessionId, data: Data(text.utf8))
    }

    /// Resize a session's terminal.
    func resize(sessionId: String, cols: Int, rows: Int) async throws {
        guard let session = sessions[sessionId] else { return }
        try await session.shellSession.resize(cols: cols, rows: rows)
    }

    func getSession(_ id: String) -> RemotePtySession? {
        sessions[id]
    }

    func stopAllSessions() async {
        for id in sessions.keys {
            await stopSession(id)
        }
    }
}

// MARK: - Remote PTY Session

class RemotePtySession: Identifiable, @unchecked Sendable {
    let id: String
    let connectionId: String
    let providerId: ProviderId
    let shellSession: SSHShellSession

    /// Buffers output data until onOutput is set (handles timing between
    /// session creation and TerminalView attachment).
    private var outputBuffer: [Data] = []

    var onOutput: ((Data) -> Void)? {
        didSet {
            // Flush any buffered data when the callback is set
            if let onOutput {
                for data in outputBuffer {
                    onOutput(data)
                }
                outputBuffer.removeAll()
            }
        }
    }
    var onExit: (() -> Void)?

    init(id: String, connectionId: String, providerId: ProviderId, shellSession: SSHShellSession) {
        self.id = id
        self.connectionId = connectionId
        self.providerId = providerId
        self.shellSession = shellSession

        // Wire up callbacks with buffering
        shellSession.onData = { [weak self] data in
            guard let self else { return }
            if let onOutput = self.onOutput {
                onOutput(data)
            } else {
                self.outputBuffer.append(data)
            }
        }
        shellSession.onClose = { [weak self] in
            self?.onExit?()
        }
    }

    func close() async {
        await shellSession.close()
    }
}

// MARK: - PTY ID Helpers

/// Matches Electron's ptyId.ts format: {providerId}-main-{taskId} or {providerId}-chat-{conversationId}
enum PtyIdHelper {
    enum Kind: String {
        case main
        case chat
    }

    static func make(providerId: ProviderId, kind: Kind, suffix: String) -> String {
        "\(providerId.rawValue)-\(kind.rawValue)-\(suffix)"
    }

    static func parse(_ ptyId: String) -> (providerId: ProviderId, kind: Kind, suffix: String)? {
        // Try each provider ID, longest first to avoid prefix ambiguity
        let sortedProviders = ProviderId.allCases.sorted { $0.rawValue.count > $1.rawValue.count }

        for provider in sortedProviders {
            let prefix = provider.rawValue + "-"
            guard ptyId.hasPrefix(prefix) else { continue }

            let remainder = String(ptyId.dropFirst(prefix.count))

            for kind in [Kind.main, Kind.chat] {
                let kindPrefix = kind.rawValue + "-"
                guard remainder.hasPrefix(kindPrefix) else { continue }
                let suffix = String(remainder.dropFirst(kindPrefix.count))
                return (provider, kind, suffix)
            }
        }
        return nil
    }
}

enum RemotePtyError: LocalizedError {
    case invalidShell(String)
    case sessionNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidShell(let shell):
            return "Shell not in allowlist: \(shell)"
        case .sessionNotFound(let id):
            return "PTY session not found: \(id)"
        }
    }
}
