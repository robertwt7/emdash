import Foundation
import SwiftData

@Model
final class ChatMessage {
    @Attribute(.unique) var id: String
    var content: String
    var sender: String
    var timestamp: Date
    var metadata: String? // JSON

    var conversation: Conversation?

    init(
        id: String = UUID().uuidString,
        content: String,
        sender: String,
        conversation: Conversation?,
        metadata: String? = nil
    ) {
        self.id = id
        self.content = content
        self.sender = sender
        self.conversation = conversation
        self.timestamp = Date()
    }
}
