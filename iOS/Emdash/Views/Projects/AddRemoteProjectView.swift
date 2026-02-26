import SwiftUI
import SwiftData

/// 4-step wizard for adding a remote project via SSH.
/// Mirrors Electron's AddRemoteProjectModal.
struct AddRemoteProjectView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    enum WizardStep: Int, CaseIterable {
        case connection = 0
        case auth = 1
        case path = 2
        case confirm = 3

        var title: String {
            switch self {
            case .connection: "Connection"
            case .auth: "Authentication"
            case .path: "Project Path"
            case .confirm: "Confirm"
            }
        }
    }

    @State private var step: WizardStep = .connection

    // Connection fields
    @State private var connectionName = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""

    // Auth fields
    @State private var authType: AuthType = .key
    @State private var password = ""
    @State private var privateKeyPath = "~/.ssh/id_rsa"
    @State private var passphrase = ""
    @State private var showPassword = false

    // Path fields
    @State private var remotePath = "~"
    @State private var browsingPath = "/"
    @State private var remoteFiles: [RemoteFileEntry] = []
    @State private var selectedPath: String?

    // State
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var connectionId: String?
    @State private var isTestingConnection = false
    @State private var testResult: String?

    // Existing connections
    @Query(sort: \SSHConnectionModel.name) private var existingConnections: [SSHConnectionModel]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Step indicator
                stepIndicator
                    .padding()

                Divider()

                // Step content
                ScrollView {
                    VStack(spacing: 20) {
                        switch step {
                        case .connection:
                            connectionStep
                        case .auth:
                            authStep
                        case .path:
                            pathStep
                        case .confirm:
                            confirmStep
                        }

                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.horizontal)
                        }
                    }
                    .padding()
                }

                Divider()

                // Navigation buttons
                navigationButtons
                    .padding()
            }
            .navigationTitle("Add Remote Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 4) {
            ForEach(WizardStep.allCases, id: \.rawValue) { s in
                VStack(spacing: 4) {
                    Circle()
                        .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                    Text(s.title)
                        .font(.caption2)
                        .foregroundStyle(s == step ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Step 1: Connection

    private var connectionStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Existing connections
            if !existingConnections.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Saved Connections")
                        .font(.headline)

                    ForEach(existingConnections) { conn in
                        Button {
                            selectExistingConnection(conn)
                        } label: {
                            HStack {
                                Image(systemName: "server.rack")
                                VStack(alignment: .leading) {
                                    Text(conn.name)
                                        .font(.body.weight(.medium))
                                    Text(conn.displayTarget)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(12)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()
                    .padding(.vertical, 8)

                Text("New Connection")
                    .font(.headline)
            }

            TextField("Connection Name", text: $connectionName)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField("Host", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                TextField("Port", text: $port)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .frame(width: 70)
            }

            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }

    // MARK: - Step 2: Authentication

    private var authStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Authentication Method")
                .font(.headline)

            Picker("Auth Type", selection: $authType) {
                Text("SSH Key").tag(AuthType.key)
                Text("Password").tag(AuthType.password)
                Text("SSH Agent").tag(AuthType.agent)
            }
            .pickerStyle(.segmented)

            switch authType {
            case .password:
                HStack {
                    if showPassword {
                        TextField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                    }
                }

            case .key:
                TextField("Private Key Path", text: $privateKeyPath)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                SecureField("Passphrase (optional)", text: $passphrase)
                    .textFieldStyle(.roundedBorder)

            case .agent:
                Text("Will use the SSH agent running on the remote server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }

            // Test Connection
            HStack {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        if isTestingConnection {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                        Text("Test Connection")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isTestingConnection || host.isEmpty || username.isEmpty)

                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("Success") ? .green : .red)
                }
            }
        }
    }

    // MARK: - Step 3: Path Selection

    private var pathStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Select Project Directory")
                .font(.headline)

            // Current path
            HStack {
                Button {
                    navigateUp()
                } label: {
                    Image(systemName: "arrow.up.circle")
                }
                .disabled(browsingPath == "/")

                Text(browsingPath)
                    .font(.callout.monospaced())
                    .lineLimit(1)

                Spacer()

                Button("Select This") {
                    selectedPath = browsingPath
                    remotePath = browsingPath
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if isLoading {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                // File browser
                LazyVStack(spacing: 0) {
                    ForEach(remoteFiles) { entry in
                        Button {
                            if entry.isDirectory {
                                Task { await browsePath(entry.path) }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: entry.icon)
                                    .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                                    .frame(width: 20)

                                Text(entry.name)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Spacer()

                                if entry.isDirectory {
                                    if selectedPath == entry.path {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }

                                    Button {
                                        selectedPath = entry.path
                                        remotePath = entry.path
                                    } label: {
                                        Text("Select")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)

                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                        }
                        .buttonStyle(.plain)

                        Divider()
                    }
                }
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let selected = selectedPath {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Selected: \(selected)")
                        .font(.caption)
                }
            }
        }
        .task {
            if remoteFiles.isEmpty {
                await browsePath(browsingPath)
            }
        }
    }

    // MARK: - Step 4: Confirm

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review & Confirm")
                .font(.headline)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    confirmRow("Name", value: connectionName.isEmpty ? host : connectionName)
                    confirmRow("Host", value: "\(host):\(port)")
                    confirmRow("Username", value: username)
                    confirmRow("Auth", value: authType.rawValue.capitalized)
                    confirmRow("Path", value: remotePath)
                }
            }

            if isLoading {
                ProgressView("Creating project...")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func confirmRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.callout.monospaced())
        }
    }

    // MARK: - Navigation Buttons

    private var navigationButtons: some View {
        HStack {
            if step != .connection {
                Button("Back") {
                    withAnimation {
                        step = WizardStep(rawValue: step.rawValue - 1) ?? .connection
                    }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if step == .confirm {
                Button("Create Project") {
                    Task { await createProject() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
            } else {
                Button("Next") {
                    withAnimation {
                        advanceStep()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdvance)
            }
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .connection:
            return !host.isEmpty && !username.isEmpty
        case .auth:
            switch authType {
            case .password: return !password.isEmpty
            case .key: return !privateKeyPath.isEmpty
            case .agent: return true
            }
        case .path:
            return selectedPath != nil || !remotePath.isEmpty
        case .confirm:
            return true
        }
    }

    // MARK: - Actions

    private func advanceStep() {
        guard let next = WizardStep(rawValue: step.rawValue + 1) else { return }

        if step == .auth {
            // Connect before moving to path step
            Task {
                isLoading = true
                errorMessage = nil
                do {
                    let connId = UUID().uuidString
                    self.connectionId = connId

                    _ = try await appState.sshService.connect(
                        connectionId: connId,
                        host: host,
                        port: Int(port) ?? 22,
                        username: username,
                        authType: authType,
                        privateKeyPath: authType == .key ? privateKeyPath : nil,
                        password: authType == .password ? password : nil,
                        passphrase: authType == .key ? passphrase : nil
                    )
                    appState.updateConnectionState(connId, state: .connected)
                    isLoading = false
                    step = next

                    // Start browsing home directory
                    await browseHomePath()
                } catch {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        } else {
            step = next
        }
    }

    private func selectExistingConnection(_ conn: SSHConnectionModel) {
        connectionName = conn.name
        host = conn.host
        port = "\(conn.port)"
        username = conn.username
        authType = conn.authType
        privateKeyPath = conn.privateKeyPath ?? "~/.ssh/id_rsa"

        // Try to connect and skip to path step
        Task {
            isLoading = true
            errorMessage = nil
            do {
                let password = appState.keychainService.getPassword(connectionId: conn.id)
                let passphrase = appState.keychainService.getPassphrase(connectionId: conn.id)

                _ = try await appState.sshService.connect(
                    connectionId: conn.id,
                    host: conn.host,
                    port: conn.port,
                    username: conn.username,
                    authType: conn.authType,
                    privateKeyPath: conn.privateKeyPath,
                    password: password,
                    passphrase: passphrase
                )

                connectionId = conn.id
                appState.updateConnectionState(conn.id, state: .connected)
                isLoading = false
                step = .path
                await browseHomePath()
            } catch {
                isLoading = false
                errorMessage = "Connection failed: \(error.localizedDescription)"
            }
        }
    }

    private func testConnection() async {
        isTestingConnection = true
        testResult = nil
        defer { isTestingConnection = false }

        do {
            let tempId = "test-\(UUID().uuidString)"
            _ = try await appState.sshService.connect(
                connectionId: tempId,
                host: host,
                port: Int(port) ?? 22,
                username: username,
                authType: authType,
                privateKeyPath: authType == .key ? privateKeyPath : nil,
                password: authType == .password ? password : nil,
                passphrase: authType == .key ? passphrase : nil
            )
            await appState.sshService.disconnect(connectionId: tempId)
            testResult = "Success!"
        } catch {
            testResult = "Failed: \(error.localizedDescription)"
        }
    }

    private func browseHomePath() async {
        guard let connId = connectionId else { return }
        do {
            let result = try await appState.sshService.executeCommand(
                connectionId: connId, command: "echo $HOME"
            )
            let home = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !home.isEmpty {
                browsingPath = home
                await browsePath(home)
            }
        } catch {
            await browsePath("/")
        }
    }

    private func browsePath(_ path: String) async {
        guard let connId = connectionId else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            browsingPath = path
            remoteFiles = try await appState.sshService.listFiles(connectionId: connId, path: path)
        } catch {
            errorMessage = "Browse failed: \(error.localizedDescription)"
        }
    }

    private func navigateUp() {
        let parent = (browsingPath as NSString).deletingLastPathComponent
        Task { await browsePath(parent) }
    }

    private func createProject() async {
        guard let connId = connectionId else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // Verify it's a git repo
            let isGit = try await appState.remoteGitService.isGitRepo(
                connectionId: connId, path: remotePath
            )

            if !isGit {
                errorMessage = "Selected path is not a git repository"
                return
            }

            // Save or reuse SSH connection
            let sshConnection: SSHConnectionModel
            if let existing = existingConnections.first(where: { $0.id == connId }) {
                sshConnection = existing
            } else {
                let name = connectionName.isEmpty ? host : connectionName
                sshConnection = SSHConnectionModel(
                    id: connId,
                    name: name,
                    host: host,
                    port: Int(port) ?? 22,
                    username: username,
                    authType: authType,
                    privateKeyPath: authType == .key ? privateKeyPath : nil,
                    useAgent: authType == .agent
                )
                modelContext.insert(sshConnection)

                // Store credentials
                if authType == .password && !password.isEmpty {
                    try? appState.keychainService.storePassword(connectionId: connId, password: password)
                }
                if authType == .key && !passphrase.isEmpty {
                    try? appState.keychainService.storePassphrase(connectionId: connId, passphrase: passphrase)
                }
            }

            // Get git info
            let branch = try? await appState.remoteGitService.getCurrentBranch(
                connectionId: connId, cwd: remotePath
            )
            let remoteUrl = try? await appState.remoteGitService.getRemoteUrl(
                connectionId: connId, cwd: remotePath
            )

            // Create project
            let projectName = (remotePath as NSString).lastPathComponent
            let project = ProjectModel(
                name: projectName,
                remotePath: remotePath,
                sshConnection: sshConnection,
                gitRemote: remoteUrl,
                gitBranch: branch
            )
            modelContext.insert(project)

            try modelContext.save()

            // Select the new project
            appState.selectProject(project)
            dismiss()

        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
