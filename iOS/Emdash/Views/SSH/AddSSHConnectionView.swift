import SwiftUI
import SwiftData

/// Form for adding a new SSH connection.
struct AddSSHConnectionView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authType: AuthType = .key
    @State private var password = ""
    @State private var privateKeyPath = "~/.ssh/id_rsa"
    @State private var passphrase = ""
    @State private var showPassword = false
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Name", text: $name)
                    HStack {
                        TextField("Host", text: $host)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("Port", text: $port)
                            .keyboardType(.numberPad)
                            .frame(width: 70)
                    }
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("Authentication") {
                    Picker("Type", selection: $authType) {
                        Text("SSH Key").tag(AuthType.key)
                        Text("Password").tag(AuthType.password)
                        Text("Agent").tag(AuthType.agent)
                    }
                    .pickerStyle(.segmented)

                    switch authType {
                    case .password:
                        HStack {
                            if showPassword {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                            Button {
                                showPassword.toggle()
                            } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                            }
                        }
                    case .key:
                        TextField("Key Path", text: $privateKeyPath)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        SecureField("Passphrase", text: $passphrase)
                    case .agent:
                        Text("SSH agent will be used for authentication")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    HStack {
                        Button {
                            Task { await testConnection() }
                        } label: {
                            HStack {
                                if isTesting { ProgressView().scaleEffect(0.7) }
                                Text("Test Connection")
                            }
                        }
                        .disabled(isTesting || host.isEmpty || username.isEmpty)

                        if let result = testResult {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(result.contains("Success") ? .green : .red)
                        }
                    }
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .navigationTitle("New Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await saveConnection() }
                    }
                    .disabled(host.isEmpty || username.isEmpty || isSaving)
                }
            }
        }
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }

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

    private func saveConnection() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let connId = UUID().uuidString
        let connName = name.isEmpty ? host : name

        let connection = SSHConnectionModel(
            id: connId,
            name: connName,
            host: host,
            port: Int(port) ?? 22,
            username: username,
            authType: authType,
            privateKeyPath: authType == .key ? privateKeyPath : nil,
            useAgent: authType == .agent
        )

        modelContext.insert(connection)

        // Store credentials in keychain
        if authType == .password && !password.isEmpty {
            try? appState.keychainService.storePassword(connectionId: connId, password: password)
        }
        if authType == .key && !passphrase.isEmpty {
            try? appState.keychainService.storePassphrase(connectionId: connId, passphrase: passphrase)
        }

        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
