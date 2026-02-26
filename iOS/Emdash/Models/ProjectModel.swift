import Foundation
import SwiftData

@Model
final class ProjectModel {
    @Attribute(.unique) var id: String
    var name: String
    var remotePath: String
    var gitRemote: String?
    var gitBranch: String?
    var baseRef: String?
    var githubRepository: String?
    var createdAt: Date
    var updatedAt: Date

    var sshConnection: SSHConnectionModel?

    @Relationship(deleteRule: .cascade, inverse: \AgentTask.project)
    var tasks: [AgentTask]?

    init(
        id: String = UUID().uuidString,
        name: String,
        remotePath: String,
        sshConnection: SSHConnectionModel?,
        gitRemote: String? = nil,
        gitBranch: String? = nil,
        baseRef: String? = nil,
        githubRepository: String? = nil
    ) {
        self.id = id
        self.name = name
        self.remotePath = remotePath
        self.sshConnection = sshConnection
        self.gitRemote = gitRemote
        self.gitBranch = gitBranch
        self.baseRef = baseRef
        self.githubRepository = githubRepository
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var connectionId: String? { sshConnection?.id }

    var sortedTasks: [AgentTask] {
        (tasks ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    var activeTasks: [AgentTask] {
        sortedTasks.filter { $0.archivedAt == nil }
    }

    var archivedTasks: [AgentTask] {
        sortedTasks.filter { $0.archivedAt != nil }
    }
}
