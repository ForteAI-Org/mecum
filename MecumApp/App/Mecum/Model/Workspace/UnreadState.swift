//
//  UnreadState.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// UnreadState is what a worker's direct conversation holds that the person
/// has not seen yet (§4.3).
///
/// It is derived from the store on every read, from the conversation's read
/// marker, and never kept only in memory, so it survives a relaunch.
nonisolated struct UnreadState: Sendable, Hashable {

    /// Nothing unseen.
    static let none = UnreadState(replies: 0, hasUnseenProblem: false)

    /// Replies the conversation's own worker wrote past the read marker. A
    /// message by the person, or by any other worker, is never counted.
    let replies: Int

    /// A turn failed or was stopped past the read marker. It is a problem to
    /// look at rather than a number, so the row marks it instead of counting.
    let hasUnseenProblem: Bool

    init(replies: Int, hasUnseenProblem: Bool) {
        self.replies          = replies
        self.hasUnseenProblem = hasUnseenProblem
    }
}
