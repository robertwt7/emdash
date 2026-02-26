import Foundation
import SwiftData

enum TaskStatus: String, Codable {
    case idle
    case running
    case completed
    case failed
    case archived
}

@Model
final class AgentTask {
    @Attribute(.unique) var id: String
    var name: String
    var branch: String?
    var worktreePath: String?
    var status: TaskStatus
    var agentId: String?
    var metadata: String? // JSON string
    var archivedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    var project: ProjectModel?

    @Relationship(deleteRule: .cascade, inverse: \Conversation.task)
    var conversations: [Conversation]?

    init(
        id: String = UUID().uuidString,
        name: String,
        project: ProjectModel?,
        branch: String? = nil,
        worktreePath: String? = nil,
        status: TaskStatus = .idle,
        agentId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.project = project
        self.branch = branch
        self.worktreePath = worktreePath
        self.status = status
        self.agentId = agentId
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var sortedConversations: [Conversation] {
        (conversations ?? []).sorted { $0.displayOrder < $1.displayOrder }
    }

    var mainConversation: Conversation? {
        conversations?.first { $0.isMain }
    }

    var isArchived: Bool { archivedAt != nil }
    var isRunning: Bool { status == .running }
}
