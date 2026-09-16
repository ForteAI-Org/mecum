//
//  InputCommandKind.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

/// InputCommandKind identifies the shape of a traced Command without retaining
/// text, coordinates or any other command payload.
public enum InputCommandKind: Sendable, Equatable {
    case key
    case text
    case insertText
    case click
    case drag
    case scroll
}

extension InputCommand {

    public var kind: InputCommandKind {
        switch self {
            case .key:        .key
            case .text:       .text
            case .insertText: .insertText
            case .click:      .click
            case .drag:       .drag
            case .scroll:     .scroll
        }
    }
}
