import SwiftUI
import SwiftData

/// Task creation form. Mirrors Electron's TaskModal.
struct CreateTaskView: View {
    let project: ProjectModel
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss

    @State private var taskName = ""
    @State private var initialPrompt = ""
    @State private var selectedProvider: ProviderId = .claude
    @State private var autoApprove = true
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var envVars: [(key: String, value: String)] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Task Name", text: $taskName)
                        .autocorrectionDisabled()

                    TextEditor(text: $initialPrompt)
                        .frame(minHeight: 80)
                        .overlay(alignment: .topLeading) {
                            if initialPrompt.isEmpty {
                                Text("Initial prompt for the agent...")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                Section("Agent") {
                    agentPicker

                    Toggle("Auto-approve", isOn: $autoApprove)

                    if let provider = ProviderRegistry.provider(for: selectedProvider) {
                        if provider.autoApproveFlag == nil {
                            Text("This agent doesn't support auto-approve")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Environment Variables") {
                    ForEach(envVars.indices, id: \.self) { index in
                        HStack {
                            TextField("Key", text: Binding(
                                get: { envVars[index].key },
                                set: { envVars[index].key = $0 }
                            ))
                            .font(.callout.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                            TextField("Value", text: Binding(
                                get: { envVars[index].value },
                                set: { envVars[index].value = $0 }
                            ))
                            .font(.callout.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                            Button {
                                envVars.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    Button {
                        envVars.append((key: "", value: ""))
                    } label: {
                        Label("Add Variable", systemImage: "plus.circle")
                    }
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await createTask() }
                    }
                    .disabled(taskName.isEmpty || isCreating)
                }
            }
            .overlay {
                if isCreating {
                    ZStack {
                        Color.black.opacity(0.3)
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Creating task...")
                                .font(.callout)
                        }
                        .padding(24)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .ignoresSafeArea()
                }
            }
        }
    }

    // MARK: - Agent Picker

    private var agentPicker: some View {
        let detected = appState.detectedAgents[project.connectionId ?? ""] ?? []
        let available = detected.isEmpty ? ProviderId.allCases : detected

        return Picker("Agent", selection: $selectedProvider) {
            ForEach(available, id: \.self) { providerId in
                if let provider = ProviderRegistry.provider(for: providerId) {
                    Label(provider.name, systemImage: provider.icon ?? "terminal")
                        .tag(providerId)
                }
            }
        }
    }

    // MARK: - Create

    private func createTask() async {
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        do {
            let env = Dictionary(
                uniqueKeysWithValues: envVars
                    .filter { !$0.key.isEmpty && !$0.value.isEmpty }
                    .map { ($0.key, $0.value) }
            )

            let task = try await appState.agentManager.createAndStartTask(
                project: project,
                name: taskName,
                providerId: selectedProvider,
                initialPrompt: initialPrompt.isEmpty ? nil : initialPrompt,
                autoApprove: autoApprove,
                env: env,
                modelContext: modelContext
            )

            appState.selectTask(task)
            dismiss()
            // Navigate to task detail after sheet dismisses (iPhone)
            if sizeClass != .regular {
                // Small delay to let sheet dismiss before pushing navigation
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    appState.navigationPath.append(NavigationDestination.task(task))
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
