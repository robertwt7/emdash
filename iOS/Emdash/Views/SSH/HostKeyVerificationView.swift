import SwiftUI

/// Host key verification dialog.
/// Shown when connecting to a new or changed host.
struct HostKeyVerificationView: View {
    let host: String
    let port: Int
    let fingerprint: String
    let algorithm: String
    let status: HostKeyStatus
    let onAccept: () -> Void
    let onReject: () -> Void

    enum HostKeyStatus {
        case new
        case changed
    }

    var body: some View {
        VStack(spacing: 20) {
            // Warning icon
            Image(systemName: status == .new ? "questionmark.key.filled" : "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(status == .new ? .yellow : .red)

            // Title
            Text(status == .new ? "Unknown Host" : "Host Key Changed!")
                .font(.title2.bold())
                .foregroundStyle(status == .changed ? .red : .primary)

            // Description
            Text(statusDescription)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            // Fingerprint
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Host", value: port == 22 ? host : "\(host):\(port)")
                    LabeledContent("Algorithm", value: algorithm)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fingerprint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(fingerprint)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }

            if status == .changed {
                Text("WARNING: This could indicate a man-in-the-middle attack. Only proceed if you trust this connection.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            // Actions
            HStack(spacing: 16) {
                Button("Reject", role: .destructive) {
                    onReject()
                }
                .buttonStyle(.bordered)

                Button(status == .new ? "Accept & Connect" : "Accept New Key") {
                    onAccept()
                }
                .buttonStyle(.borderedProminent)
                .tint(status == .changed ? .orange : .blue)
            }
        }
        .padding(24)
    }

    private var statusDescription: String {
        switch status {
        case .new:
            return "You're connecting to \(host) for the first time. Please verify the host key fingerprint."
        case .changed:
            return "The host key for \(host) has changed since your last connection. This may be due to server reconfiguration or a security issue."
        }
    }
}
