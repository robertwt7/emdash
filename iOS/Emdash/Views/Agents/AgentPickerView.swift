import SwiftUI

/// Agent picker used in task creation and conversation addition.
struct AgentPickerView: View {
    @Binding var selectedProvider: ProviderId
    let availableProviders: [ProviderId]

    var body: some View {
        List {
            ForEach(availableProviders, id: \.self) { providerId in
                if let provider = ProviderRegistry.provider(for: providerId) {
                    Button {
                        selectedProvider = providerId
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: provider.icon ?? "terminal")
                                .font(.title3)
                                .frame(width: 32, height: 32)
                                .foregroundStyle(.blue)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)

                                if let cli = provider.effectiveCli {
                                    Text(cli)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            if selectedProvider == providerId {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Select Agent")
    }
}
