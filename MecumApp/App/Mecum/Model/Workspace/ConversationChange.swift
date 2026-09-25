//
//  ConversationChange.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import ModelTransports

/// ConversationChange names one edit to a conversation.
nonisolated enum ConversationChange: Sendable, Equatable {
    case title(String?)
    case participants([UUID])
    case draft(String)
    case readingPosition(anchorMessageID: UUID?, offset: Double)

    /// The session `provider` reported for this conversation. It replaces any
    /// earlier one, including one from another provider.
    case providerSession(provider: ModelProvider, id: String)

    /// No provider session: the next turn starts a new one, whichever provider answers it.
    case providerSessionCleared
}
