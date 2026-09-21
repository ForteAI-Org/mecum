//
//  RecencyOrder.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// RecencyOrder is the Window Recency of one assigned application: the last
/// qualified appearance, reappearance or return to the front of each surface,
/// and the answer to "which of these is the most recent".
///
/// ## It can answer that it does not know
///
/// The answer is three-valued on purpose. `notObserved` means no candidate
/// carries a qualified event, which is the state at a handover, and `ambiguous`
/// means several carry one at the same instant. Neither is resolved by falling
/// back to the Window ID, the order the claims arrived in or the order of the
/// members: an order nobody observed is not an order, and the selection asks the
/// consumer instead of inventing one.
///
/// ## What it stores
///
/// One mark per surface, replaced only by a strictly later one, so a result that
/// arrives late updates nothing and cannot move a target. Qualification of the
/// claim itself happens before anything gets here: this type stores marks and
/// compares instants.
nonisolated package struct RecencyOrder: Sendable, Equatable {

    /// The last qualified event of one surface.
    nonisolated package struct Mark: Sendable, Equatable {

        package let signal               : RecencySignal
        package let observedAtNanoseconds: UInt64

        package init(signal: RecencySignal, observedAtNanoseconds: UInt64) {
            self.signal                = signal
            self.observedAtNanoseconds = observedAtNanoseconds
        }
    }

    /// What the order can say about a set of candidates.
    nonisolated package enum Answer: Sendable, Equatable {

        /// No candidate carries a qualified event.
        case notObserved

        case one(WindowIdentity)

        /// Several candidates carry their qualified event at the same instant,
        /// so their relative order was not observed.
        case ambiguous([WindowIdentity])
    }

    package private(set) var marks: [WindowIdentity: Mark] = [:]

    package init() {}

    /// Records a qualified event, and answers whether it was newer than what was
    /// already known about that surface.
    @discardableResult
    package mutating func record(
        _ surface: WindowIdentity,
        signal   : RecencySignal,
        at instant: UInt64
    ) -> Bool {

        if let existing = marks[surface], existing.observedAtNanoseconds >= instant { return false }
        marks[surface] = Mark(signal: signal, observedAtNanoseconds: instant)
        return true
    }

    package mutating func forget(_ surface: WindowIdentity) {
        marks[surface] = nil
    }

    /// The most recent of the candidates, or the reason there is no single one.
    ///
    /// A candidate with no mark loses to one with a mark: something qualified
    /// was observed about the second and nothing at all about the first. Ties are
    /// answered as a tie, and the list is sorted by Window ID only so that a
    /// report is stable, never to choose between them.
    package func mostRecent(among candidates: [WindowIdentity]) -> Answer {

        var latest : UInt64            = 0
        var leaders: [WindowIdentity]  = []

        for candidate in candidates {
            guard let mark = marks[candidate] else { continue }
            if leaders.isEmpty || mark.observedAtNanoseconds > latest {
                latest  = mark.observedAtNanoseconds
                leaders = [candidate]
            } else if mark.observedAtNanoseconds == latest {
                leaders.append(candidate)
            }
        }
        guard let single = leaders.first else { return .notObserved }
        guard leaders.count > 1 else { return .one(single) }
        return .ambiguous(leaders.sorted { $0.windowNumber < $1.windowNumber })
    }
}
