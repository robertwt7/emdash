import Foundation
import Citadel
import NIO
import NIOSSH

/// SSH connection pool and command execution service.
/// Port of Electron's SshService using Citadel (SwiftNIO SSH).
actor SSHService {
    private var connections: [String: SSHConnection] = [:]
    private var pendingConnections: [String: Task<SSHConnection, Error>] = [:]
    private let maxConnections = 10
    private let keychainService = KeychainService()

    struct SSHConnection {
        let id: String
        let client: SSHClient
        let config: SSHConnectionConfig
        let connectedAt: Date
        var lastActivity: Date
    }

    struct SSHConnectionConfig {
        let host: String
        let port: Int
        let username: String
        let authType: AuthType
        let privateKeyPath: String?
        let password: String?
        let passphrase: String?
    }

    struct ExecResult {
        let stdout: String
        let stderr: String
        let exitCode: Int
    }

    // MARK: - Connection Management

    func connect(
        connectionId: String,
        host: String,
        port: Int,
        username: String,
        authType: AuthType,
        privateKeyPath: String? = nil,
        password: String? = nil,
        passphrase: String? = nil
    ) async throws -> SSHConnection {
        // Return existing connection if alive
        if let existing = connections[connectionId] {
            return existing
        }

        // Coalesce concurrent connect calls
        if let pending = pendingConnections[connectionId] {
            return try await pending.value
        }

        guard connections.count < maxConnections else {
            throw SSHError.maxConnectionsReached
        }

        let task = Task<SSHConnection, Error> {
            let config = SSHConnectionConfig(
                host: host, port: port, username: username,
                authType: authType, privateKeyPath: privateKeyPath,
                password: password, passphrase: passphrase
            )

            let client = try await self.createClient(config: config)
            let conn = SSHConnection(
                id: connectionId,
                client: client,
                config: config,
                connectedAt: Date(),
                lastActivity: Date()
            )
            return conn
        }

        pendingConnections[connectionId] = task
        defer { pendingConnections.removeValue(forKey: connectionId) }

        let connection = try await task.value
        connections[connectionId] = connection
        Log.ssh.info("Connected to \(host):\(port) as \(username)")
        return connection
    }

    private func createClient(config: SSHConnectionConfig) async throws -> SSHClient {
        let authMethod: SSHAuthenticationMethod

        switch config.authType {
        case .password:
            guard let pw = config.password ?? keychainService.getPassword(connectionId: "") else {
                throw SSHError.missingCredentials("Password not provided")
            }
            authMethod = .passwordBased(username: config.username, password: pw)

        case .key:
            // TODO: Implement proper SSH key auth with Citadel.
            // Citadel's key auth API varies by version. Needs:
            // 1. PEM key parsing (ED25519, RSA, ECDSA)
            // 2. Passphrase decryption for encrypted keys
            // 3. Proper SSHAuthenticationMethod construction
            // For now, fall back to password if available, otherwise error.
            if let pw = config.password ?? keychainService.getPassword(connectionId: "") {
                authMethod = .passwordBased(username: config.username, password: pw)
                Log.ssh.warning("Key auth not yet implemented, falling back to password")
            } else {
                throw SSHError.unsupportedAuthType(
                    "SSH key authentication requires Citadel key integration (not yet implemented). " +
                    "Please use password authentication for now."
                )
            }

        case .agent:
            throw SSHError.unsupportedAuthType("SSH agent forwarding not yet supported on iOS. Use key or password auth.")
        }

        let client = try await SSHClient.connect(
            host: config.host,
            port: config.port,
            authenticationMethod: authMethod,
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )

        return client
    }

    func disconnect(connectionId: String) async {
        guard let conn = connections.removeValue(forKey: connectionId) else { return }
        try? await conn.client.close()
        Log.ssh.info("Disconnected from \(conn.config.host)")
    }

    func isConnected(_ connectionId: String) -> Bool {
        connections[connectionId] != nil
    }

    func getConnection(_ connectionId: String) -> SSHConnection? {
        connections[connectionId]
    }

    // MARK: - Command Execution

    func executeCommand(
        connectionId: String,
        command: String,
        cwd: String? = nil
    ) async throws -> ExecResult {
        guard let conn = connections[connectionId] else {
            throw SSHError.notConnected(connectionId)
        }

        let fullCommand: String
        if let cwd = cwd {
            fullCommand = "cd \(ShellEscape.quoteShellArg(cwd)) && \(command)"
        } else {
            fullCommand = command
        }

        Log.ssh.debug("Exec: \(fullCommand)")

        // Citadel throws CommandFailed when the remote command exits non-zero.
        // Catch it and return as ExecResult so callers can check exitCode.
        do {
            let buffer = try await conn.client.executeCommand(fullCommand)
            let stdout = String(buffer: buffer)
            connections[connectionId]?.lastActivity = Date()
            return ExecResult(stdout: stdout, stderr: "", exitCode: 0)
        } catch let error as SSHClient.CommandFailed {
            connections[connectionId]?.lastActivity = Date()
            return ExecResult(
                stdout: "",
                stderr: "Command failed with exit code \(error.exitCode)",
                exitCode: Int(error.exitCode)
            )
        }
    }

    // MARK: - Shell Session

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

        let client = conn.client

        let ptyTask = Task<Void, Never> {
            do {
                try await client.withPTY(ptyRequest) { inbound, outbound in
                    // Provide the writer to the session
                    session.setWriter(outbound)
                    // Start draining output
                    session.startReading(inbound: inbound)
                    // Keep the closure alive until cancelled or stream ends
                    try await withTaskCancellationHandler {
                        try await Task.sleep(for: .seconds(86400 * 365))
                    } onCancel: {
                        Log.pty.debug("PTY closure cancelled for \(connectionId)")
                    }
                }
            } catch is CancellationError {
                Log.pty.debug("PTY session cancelled for \(connectionId)")
            } catch {
                Log.pty.error("PTY session error for \(connectionId): \(error.localizedDescription)")
            }
            await MainActor.run {
                session.onClose?()
            }
        }

        session.setPtyTask(ptyTask)
        await session.waitForWriter()

        Log.ssh.info("Interactive PTY session ready for connection \(connectionId)")
        return session
    }

    // MARK: - SFTP

    func listFiles(
        connectionId: String,
        path: String
    ) async throws -> [RemoteFileEntry] {
        guard let conn = connections[connectionId] else {
            throw SSHError.notConnected(connectionId)
        }

        let sftp = try await conn.client.openSFTP()
        let listing = try await sftp.listDirectory(atPath: path)

        // listDirectory returns [SFTPMessage.Name], each containing
        // a `components` array of SFTPPathComponent with filename/attributes.
        var entries: [RemoteFileEntry] = []
        for nameMessage in listing {
            for component in nameMessage.components {
                let name = component.filename
                guard name != "." && name != ".." else { continue }
                let rawPerms = component.attributes.permissions ?? 0
                let isDir = (rawPerms & 0o40000) != 0
                entries.append(RemoteFileEntry(
                    name: name,
                    path: "\(path)/\(name)",
                    isDirectory: isDir,
                    size: Int64(component.attributes.size ?? 0)
                ))
            }
        }

        return entries.sorted { entry1, entry2 in
            if entry1.isDirectory != entry2.isDirectory {
                return entry1.isDirectory
            }
            return entry1.name.localizedCaseInsensitiveCompare(entry2.name) == .orderedAscending
        }
    }

    func disconnectAll() async {
        for id in connections.keys {
            await disconnect(connectionId: id)
        }
    }
}

// MARK: - SSH Shell Session

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

// MARK: - Supporting Types

struct RemoteFileEntry: Identifiable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64

    var id: String { path }

    var icon: String {
        isDirectory ? "folder.fill" : "doc.fill"
    }
}

enum SSHError: LocalizedError {
    case maxConnectionsReached
    case notConnected(String)
    case missingCredentials(String)
    case invalidKey
    case unsupportedAuthType(String)
    case commandFailed(String)
    case shellStartFailed

    var errorDescription: String? {
        switch self {
        case .maxConnectionsReached:
            return "Maximum SSH connections (10) reached"
        case .notConnected(let id):
            return "Not connected: \(id)"
        case .missingCredentials(let detail):
            return "Missing credentials: \(detail)"
        case .invalidKey:
            return "Invalid SSH private key"
        case .unsupportedAuthType(let detail):
            return detail
        case .commandFailed(let detail):
            return "Command failed: \(detail)"
        case .shellStartFailed:
            return "Failed to start shell session"
        }
    }
}
