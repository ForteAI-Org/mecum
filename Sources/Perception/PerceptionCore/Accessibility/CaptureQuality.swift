//
//  CaptureQuality.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

/// CaptureQuality is what the accessibility read of one capture can say about itself: whether the
/// window was found, whether the grant was there when that is knowable, whether the walk finished
/// or what stopped it, the window's role and subrole, and what was counted. Every fact is optional
/// on purpose: a producer that could not observe a fact leaves it `nil`, and the reader keeps it
/// unknown. Nothing here is inferred from the elements: an empty harvest is not a complete read,
/// and a missing window is not a denied grant.
///
/// `completeness` is derived from the facts, never stored beside them: a read is complete only when
/// the window was found, the walk finished and nothing stopped it, and no fact says the grant was
/// absent. A fact nobody observed stays unknown and never adds up to complete. Facts that contradict
/// each other (`inconsistency`) are refused by every consumer that stores or reads them.
public struct CaptureQuality: Sendable, Equatable, Hashable {

    /// Completeness is the capture's status, the vocabulary the living memory stores on a sample.
    public enum Completeness: String, Sendable, Equatable, Hashable, CaseIterable {

        /// A found window, a walk that reached the end of the tree, no limit met, no denied grant.
        case complete

        /// The walk stopped before the end; what was read is right, what was not read is unknown.
        case partial

        /// Nothing could be read: no window matched the capture, or the grant is absent.
        case failed

        /// No accessibility read took place, the producer did not say, or a fact the conclusion
        /// needs (the window) was not observed.
        case unknown
    }

    /// Inconsistency is a contradiction between the facts: a walk cannot have both reached the end
    /// of the tree and been stopped by a limit, and a count cannot be negative. A quality with an
    /// inconsistency describes no read and is refused, never repaired.
    public enum Inconsistency: Sendable, Equatable, Hashable {

        /// `walkCompleted` is true and `stoppedBy` names a limit.
        case completedWalkWasStopped

        /// `nodesVisited` or `elementsEmitted` is below zero.
        case negativeCount
    }

    /// StopReason is the limit that ended a walk before the end of the tree: the deadline, the
    /// element budget, the table budget or the depth budget. The first limit met is the one kept.
    public enum StopReason: String, Sendable, Equatable, Hashable, CaseIterable {

        case deadline
        case elementLimit = "element_limit"
        case tableLimit   = "table_limit"
        case depthLimit   = "depth_limit"
    }

    /// Whether the walk reached the end of the tree; nil when no walk ran.
    public var walkCompleted: Bool?

    /// The limit that stopped the walk, when one did.
    public var stoppedBy: StopReason?

    /// Whether a window matching the capture was found in the tree; nil when nobody looked.
    public var windowFound: Bool?

    /// Whether the Accessibility grant was available to the reading process, when knowable.
    public var isGrantAvailable: Bool?

    /// The role and subrole of the window the walk started from, as the toolkit reported them.
    public var windowRole: String?
    public var windowSubrole: String?

    /// Nodes the walk read a role from, and elements it emitted, when a walk ran.
    public var nodesVisited: Int?
    public var elementsEmitted: Int?

    public init(
        walkCompleted   : Bool?       = nil,
        stoppedBy       : StopReason? = nil,
        windowFound     : Bool?       = nil,
        isGrantAvailable: Bool?       = nil,
        windowRole      : String?     = nil,
        windowSubrole   : String?     = nil,
        nodesVisited    : Int?        = nil,
        elementsEmitted : Int?        = nil
    ) {
        self.walkCompleted    = walkCompleted
        self.stoppedBy        = stoppedBy
        self.windowFound      = windowFound
        self.isGrantAvailable = isGrantAvailable
        self.windowRole       = windowRole
        self.windowSubrole    = windowSubrole
        self.nodesVisited     = nodesVisited
        self.elementsEmitted  = elementsEmitted
    }

    /// No accessibility read took place, or nothing is known about it.
    public static let unknown = CaptureQuality()

    /// The status the facts add up to: a denied grant or a missing window is `failed`; a stopped
    /// walk is `partial`; a finished, unstopped walk of a found window is `complete`; anything else
    /// is `unknown`, including a finished walk of a window nobody confirmed. An inconsistent quality
    /// has no meaningful status; consumers refuse it before asking.
    public var completeness: Completeness {
        if isGrantAvailable == false || windowFound == false { return .failed }
        if walkCompleted == false { return .partial }
        if walkCompleted == true, stoppedBy == nil, windowFound == true { return .complete }
        return .unknown
    }

    /// True only for a found window and a finished, unstopped walk: what a structural decision may
    /// rely on. An unknown window is never complete.
    public var isComplete: Bool { completeness == .complete }

    /// The first contradiction among the facts, or nil when they can all be true at once.
    public var inconsistency: Inconsistency? {
        if walkCompleted == true, stoppedBy != nil { return .completedWalkWasStopped }
        if let nodesVisited, nodesVisited < 0 { return .negativeCount }
        if let elementsEmitted, elementsEmitted < 0 { return .negativeCount }
        return nil
    }
}
