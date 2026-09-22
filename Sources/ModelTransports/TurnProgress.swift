//
//  TurnProgress.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// What a provider's stream has said so far about one turn, apart from the
/// text itself. A provider's event decoder fills this as events arrive: the
/// counts come in their own events, sometimes before the first delta and
/// sometimes with the last.
struct TurnProgress: Sendable {

    var inputTokens: Int?
    var outputTokens: Int?

    /// Generation time the provider measures itself, when it reports one. Nil
    /// leaves the wall clock to answer for the turn.
    var generated: Duration?

    /// The provider declared the turn finished. Nothing else may declare it.
    var isFinished = false

    func usage(wallClock: Duration) -> ModelUsage {
        ModelUsage(inputTokens: inputTokens, outputTokens: outputTokens, duration: generated ?? wallClock)
    }
}
