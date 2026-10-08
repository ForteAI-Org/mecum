//
//  BrainProjectionError.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

/// BrainProjectionError is what the brain's stored projection answers when a brain cannot be
/// written as it is or a stored row cannot be read back as the brain the writer had. Every case is
/// a refusal: the mutation that met it on the way in is rolled back whole, a row that meets it on
/// the way out is not read as a lesser row, and no value is defaulted. The cases carry identifiers,
/// codes and column names, never a label or a title.
public enum BrainProjectionError: Error, Sendable, Equatable {

    /// An effect string the vocabulary cannot store and rebuild exactly.
    case unrepresentableEffect(String, EffectProblem)

    /// A stored `effect_kind` outside the six families.
    case unknownEffectKind(String)

    /// A stored effect whose columns do not have its family's shape.
    case malformedEffect(String, EffectShape)

    /// A closed vocabulary met a stored code it does not list.
    case unknownElementKind(String)
    case unknownLabelSource(String)
    case unknownGroupAxis(String)
    case unknownTrigger(String)
    case unknownControlState(String)
    case unknownAnchorScope(String)
    case unknownTransitionStatus(String)

    /// A stored row of the projection breaks its shape; the id names the row.
    case malformedRow(table: String, id: String, malformation: Malformation)

    /// The algorithm dropped a row and reported no cause for it: nothing is retired on a guess.
    case unexplainedRemoval(table: String, id: String)

    /// A brain's number is NaN or an infinity: the file would keep NULL for NaN and an infinity
    /// for an infinity, and neither reads back as the number the brain had.
    case unrepresentableNumber(table: String, id: String, column: String)

    /// A date could not be converted to or from the millisecond columns.
    case clock(BrainClock.Problem)

    /// EffectProblem says why an effect string is unrepresentable.
    public enum EffectProblem: Sendable, Equatable {

        /// `SceneEffect(encoded:)` answers nil: an unknown family or a malformed payload.
        case undecodable

        /// The decoded effect encodes to another string, so the columns would rebuild a different
        /// fact: an empty label beside others, which the separator loses.
        case notCanonical
    }

    /// EffectShape says which column rule a stored effect breaks.
    public enum EffectShape: Sendable, Equatable {
        case missingText, forbiddenText, missingState, forbiddenState, forbiddenItems, notCanonical
    }

    /// Malformation says which shape rule a stored row breaks.
    public enum Malformation: Sendable, Equatable {

        /// A required column is NULL.
        case missingColumn(String)

        /// A column holds a value this projection never writes there.
        case forbiddenColumn(String)

        /// A REAL column holds NaN or an infinity.
        case nonFiniteNumber(String)

        /// A text that must be a UUID is not one.
        case notAUUID(String)

        /// Two active transitions share one (anchor, trigger, effect) triple.
        case duplicateTransition

        /// A cached `status` disagrees with the trust the effect and evidence derive.
        case statusContradictsEvidence

        /// Menu item positions are not 0, 1, 2, ... in order.
        case itemPositionsNotContiguous

        /// The transition's source is not the application's scope. No reader produces it any more:
        /// a transition from another scene is a general arc of `BrainGraphStoring`, not one the
        /// projection loads. The case stays so the public type does not change.
        case sourceIsNotTheAppScope
    }
}
