//
//  TextChunking.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import SeatCore

/// TextChunking cuts a string into pieces small enough to be delivered, and it
/// cuts **only** where a person would agree a cut may happen.
///
/// Almost all of that is free. Swift's `Character` *is* the extended grapheme
/// cluster, so iterating one is already the Unicode boundary: a surrogate pair
/// cannot be split, a zero width joiner sequence cannot lose its tail, a
/// combining mark cannot be orphaned from its base, a flag cannot become two
/// regional indicators. There is no boundary algorithm here because the
/// standard library is the boundary algorithm.
///
/// What is not free is the other limit. A cluster can be arbitrarily long, so a
/// bound in clusters says nothing about the payload a single event may carry.
/// Both bounds are therefore applied, whichever is reached first, and a single
/// cluster that does not fit on its own **refuses**: splitting it would produce
/// the one thing this type exists to prevent.
nonisolated package enum TextChunking {

    /// The pieces `text` is delivered in.
    ///
    /// Each piece is at most `maximumClusters` grapheme clusters and at most
    /// `maximumCodeUnits` UTF-16 code units, and every cut falls on a cluster
    /// boundary. The pieces concatenate back to the original exactly.
    package static func chunks(
        of text         : String,
        maximumClusters : Int,
        maximumCodeUnits: Int
    ) throws -> [String] {

        guard !text.isEmpty else { throw InputFailure.emptyText }
        guard maximumClusters > 0, maximumCodeUnits > 0 else {
            throw InputFailure.invalidTextLimit(
                clusters : maximumClusters,
                codeUnits: maximumCodeUnits
            )
        }

        var chunks : [String] = []
        var current = ""
        var clusters  = 0
        var codeUnits = 0

        for character in text {
            let width = String(character).utf16.count
            // A cluster that does not fit alone is refused and never split: a
            // half of a family emoji is not a smaller family emoji, it is
            // different text.
            guard width <= maximumCodeUnits else {
                throw InputFailure.textClusterTooLarge(
                    codeUnits: width,
                    maximum  : maximumCodeUnits
                )
            }
            if clusters == maximumClusters || codeUnits + width > maximumCodeUnits {
                chunks.append(current)
                current   = ""
                clusters  = 0
                codeUnits = 0
            }
            current.append(character)
            clusters  += 1
            codeUnits += width
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
