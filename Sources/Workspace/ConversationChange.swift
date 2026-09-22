//
//  ConversationChange.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// ConversationChange names one edit to a conversation.
public enum ConversationChange: Sendable, Equatable {
    case title(String?)
    case participants([UUID])
    case draft(String)
    case readingPosition(anchorMessageID: UUID?, offset: Double)
}
