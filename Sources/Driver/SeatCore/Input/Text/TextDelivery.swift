//
//  TextDelivery.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

/// TextDeliveryMode is which of the two text paths a bulk delivery uses, and it
/// decides the unit everything about that delivery is counted in.
///
/// The two are not interchangeable and the kit never substitutes one for the
/// other: `.typed` is what a hand produces and what a target watching each
/// keystroke reacts to, `.inserted` is the whole piece on one event and what a
/// field that only wants its contents set is happy with. `InputCommand` has the
/// measured cost of both.
public enum TextDeliveryMode: Sendable, Equatable {

    /// One `.text` Command per chunk, counted in grapheme clusters.
    case typed

    /// One `.insertText` Command per chunk, counted in UTF-16 code units.
    case inserted

    public var unit: TextUnit {
        switch self {
            case .typed   : .graphemeClusters
            case .inserted: .utf16CodeUnits
        }
    }
}

/// TextDeliveryLimits is how much text one chunk may carry.
///
/// Both bounds apply, whichever is reached first, because a grapheme cluster
/// can be arbitrarily long and a bound in clusters therefore says nothing about
/// the payload one event carries.
public struct TextDeliveryLimits: Sendable, Equatable {

    public let maximumClusters : Int
    public let maximumCodeUnits: Int

    public init(maximumClusters: Int, maximumCodeUnits: Int) {
        self.maximumClusters  = maximumClusters
        self.maximumCodeUnits = maximumCodeUnits
    }

    /// As large as one Command may carry, which ticket B4's sweep measured to
    /// be the right answer rather than a cautious one.
    ///
    /// An insertion costs a **constant**, not a price per character. Measured
    /// on 26A428: a Chromium renderer took 165 ms for 512 code units and 169 ms
    /// for 8192, because almost all of it is the Preparation and the 150 ms
    /// settle that family declares for an insertion; an AppKit target went from
    /// 4 ms to 11 ms across the same range. The per-unit figure falling from
    /// 322 to 20,6 microseconds is not the text getting cheaper, it is one
    /// fixed cost spread over more of it.
    ///
    /// So a smaller chunk buys nothing and pays that constant again. These sit
    /// at the ceiling a single Command may carry, which means chunking begins
    /// exactly where a Command would be refused and not before.
    public static let measured = TextDeliveryLimits(
        maximumClusters : TextLimits.maximumTypedClusters,
        maximumCodeUnits: TextLimits.maximumInsertedCodeUnits
    )
}

/// TextCommit is the outcome of a bulk delivery, and it is deliberately not a
/// `Bool`.
///
/// A boolean invites being read as "the text is in the field", which is the one
/// promise this kit never makes. What a delivery can answer is whether every
/// chunk went out and whether the recipient was still the same window after the
/// last one. Whether the text arrived anywhere is the separate question that
/// `EffectConfirmation` answers.
public enum TextCommit: Sendable, Equatable {

    /// Every chunk was posted and the recipient's identity was unchanged after
    /// the last one. It is proof of delivery, never of effect.
    case allChunksPosted

    /// The delivery stopped partway. **The chunks already posted are already
    /// inside the target** and there is no rollback: a caller that retries from
    /// the beginning duplicates them.
    case stoppedAfter(chunks: Int)
}

/// TextDeliveryOutcome is the structured account of one bulk delivery.
public struct TextDeliveryOutcome: Sendable {

    /// How much text the caller asked for, in this mode's unit.
    public let requested: TextMeasure

    /// How much of it was actually posted, in the same unit. Equal to
    /// `requested` only when the commit is `.allChunksPosted`.
    public let posted: TextMeasure

    /// How many chunks the text was cut into.
    public let chunkCount: Int

    /// One Receipt per chunk that was posted. Each one is a Command of its own,
    /// which is what makes the recipient re-verified between chunks: the driver
    /// re-reads the window's identity before building and again immediately
    /// before the first event of every Command.
    public let receipts: [InputReceipt]

    /// What happened, as an outcome and never as a guarantee.
    public let commit: TextCommit

    public init(
        requested : TextMeasure,
        posted    : TextMeasure,
        chunkCount: Int,
        receipts  : [InputReceipt],
        commit    : TextCommit
    ) {
        self.requested  = requested
        self.posted     = posted
        self.chunkCount = chunkCount
        self.receipts   = receipts
        self.commit     = commit
    }

    /// Builds the outcome from the pieces and the receipts that came back.
    ///
    /// It is here, pure and separate from the seat, because the arithmetic is
    /// the part that can be wrong in a way nobody notices: a posted count that
    /// silently counts the chunks that were *built* rather than the ones that
    /// were *delivered* would turn a partial delivery into a clean receipt.
    public static func of(
        chunks       : [String],
        mode         : TextDeliveryMode,
        receipts     : [InputReceipt],
        requestedText: String
    ) -> TextDeliveryOutcome {

        func measure(_ pieces: some Sequence<String>) -> Int {
            pieces.reduce(0) { total, piece in
                total + (mode == .typed ? piece.count : piece.utf16.count)
            }
        }

        // Only the chunks a Receipt came back for. A Receipt exists because the
        // posting loop finished, and the loop cannot fail partway.
        let delivered = chunks.prefix(receipts.count)
        let complete  = receipts.count == chunks.count

        return TextDeliveryOutcome(
            requested : TextMeasure(
                mode == .typed ? requestedText.count : requestedText.utf16.count,
                mode.unit
            ),
            posted    : TextMeasure(measure(delivered), mode.unit),
            chunkCount: chunks.count,
            receipts  : receipts,
            commit    : complete ? .allChunksPosted : .stoppedAfter(chunks: receipts.count)
        )
    }
}
