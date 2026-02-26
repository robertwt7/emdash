import Foundation
import Security

/// Keychain-based credential storage matching Electron's keytar integration.
/// Service name mirrors the desktop app: "emdash-ssh".
final class KeychainService: Sendable {
    private let serviceName = "emdash-ssh"

    // MARK: - Password

    func storePassword(connectionId: String, password: String) throws {
        let account = "\(connectionId):password"
        try store(account: account, data: Data(password.utf8))
    }

    func getPassword(connectionId: String) -> String? {
        let account = "\(connectionId):password"
        guard let data = retrieve(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deletePassword(connectionId: String) {
        let account = "\(connectionId):password"
        delete(account: account)
    }

    // MARK: - Passphrase (for SSH keys)

    func storePassphrase(connectionId: String, passphrase: String) throws {
        let account = "\(connectionId):passphrase"
        try store(account: account, data: Data(passphrase.utf8))
    }

    func getPassphrase(connectionId: String) -> String? {
        let account = "\(connectionId):passphrase"
        guard let data = retrieve(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deletePassphrase(connectionId: String) {
        let account = "\(connectionId):passphrase"
        delete(account: account)
    }

    // MARK: - Bulk

    func deleteAllCredentials(connectionId: String) {
        deletePassword(connectionId: connectionId)
        deletePassphrase(connectionId: connectionId)
    }

    // MARK: - Core Keychain Operations

    private func store(account: String, data: Data) throws {
        // Delete existing first
        delete(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unableToStore(status: status)
        }
    }

    private func retrieve(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: LocalizedError {
    case unableToStore(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .unableToStore(let status):
            return "Keychain store failed with status: \(status)"
        }
    }
}
