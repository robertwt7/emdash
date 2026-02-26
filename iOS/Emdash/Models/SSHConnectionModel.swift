import Foundation
import SwiftData

enum AuthType: String, Codable, CaseIterable {
    case password
    case key
    case agent
}

@Model
final class SSHConnectionModel {
    @Attribute(.unique) var id: String
    var name: String
    var host: String
    var port: Int
    var username: String
    var authType: AuthType
    var privateKeyPath: String?
    var useAgent: Bool
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .nullify, inverse: \ProjectModel.sshConnection)
    var projects: [ProjectModel]?

    init(
        id: String = UUID().uuidString,
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authType: AuthType = .agent,
        privateKeyPath: String? = nil,
        useAgent: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authType = authType
        self.privateKeyPath = privateKeyPath
        self.useAgent = useAgent
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var displayTarget: String {
        port == 22 ? "\(username)@\(host)" : "\(username)@\(host):\(port)"
    }
}
