import ChatCore
import FileConversations
import Foundation

/// ChatTranscript serializes live provider and tool events into one conversation on the main actor.
final class ChatTranscript {
    var conversation: Conversation
    let store: ConversationStore

    init(conversation: Conversation, store: ConversationStore) {
        self.conversation = conversation
        self.store = store
    }

    func append(_ kind: Conversation.Entry.Kind, _ text: String) throws {
        conversation.append(kind, text)
        try save()
    }

    func event(_ event: ProviderEvent) throws {
        switch event {
        case .session(let id):
            if conversation.providerSessionID != id {
                conversation.providerSessionID = id
                try save()
            }
        case .assistant(let text):
            print("\n\(conversation.provider.displayName) › \(text)\n")
            try append(.assistant, text)
        case .activity(let text): print(text)
        case .failure(let text): try append(.error, text)
        case .usage, .compacted, .completed: break
        }
    }

    func save() throws { try store.save(conversation) }
}
