import Foundation
import SwiftData

@Model
final class Conversation {
    @Attribute(.unique) var id: String
    var title: String
    var providerId: String? // ProviderId raw value
    var isActive: Bool
    var isMain: Bool
    var displayOrder: Int
    var metadata: String? // JSON
    var createdAt: Date
    var updatedAt: Date

    var task: AgentTask?

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
    var messages: [ChatMessage]?

    init(
        id: String = UUID().uuidString,
        title: String = "Main",
        task: AgentTask?,
        providerId: String? = nil,
        isActive: Bool = true,
        isMain: Bool = true,
        displayOrder: Int = 0
    ) {
        self.id = id
        self.title = title
        self.task = task
        self.providerId = providerId
        self.isActive = isActive
        self.isMain = isMain
        self.displayOrder = displayOrder
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var provider: ProviderDefinition? {
        guard let pid = providerId, let id = ProviderId(rawValue: pid) else { return nil }
        return ProviderRegistry.provider(for: id)
    }
}
