//
//  TurnRecord.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import Foundation

/// TurnRecord is a provider's own copy of one assistant turn, for a provider
/// that must be sent that turn back exactly as it produced it before a tool
/// loop may continue: Anthropic's thinking blocks, with their signatures, must
/// return unmodified beside the calls they led to, and Gemini's parts must
/// return as they came, each thought signature inside its own part.
///
/// It is opaque on purpose. Only this module makes one and reads one, and a
/// transport reads only a record its own provider made: a caller keeps it on
/// the assistant message it answers with tool results and never looks inside.
public struct TurnRecord: Sendable, Hashable {

    /// The provider whose transport made the record, and alone reads it back.
    let provider: ModelProvider

    /// The turn's content in the provider's own shape, each element one
    /// encoded JSON object, in the order the provider produced them.
    let blocks: [Data]
}
