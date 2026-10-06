//
//  InputRoute.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

/// PostRoute is the call that actually hands an event to the target process.
/// There is one explicit route per send and no implicit fallback: a route that
/// cannot be resolved fails the send instead of posting to the User Seat.
public enum PostRoute: String, Sendable, Equatable {

    /// `CGEventPostToPid`, the public CoreGraphics call.
    case publicProcess

    /// `SLEventPostToPid`, one private call, resolved and gated per build.
    case skyLightProcess

    /// No event at all: an accessibility action or attribute write on the
    /// element under the point of an out of process panel's content, whose
    /// routed events activate the host application (ADR 0031).
    case accessibilityAction
}

/// InputRoute records where the events of one send actually went: which call
/// posted them, how many of them carried a window route, and the window and
/// connection they were routed to. It carries fields and not a prose sentence,
/// so a report prints the ones it wants and a test can assert on them.
public struct InputRoute: Sendable, Equatable {

    /// The call used to post every event of the send.
    public let poster: PostRoute

    /// How many events carried a window route. Keyboard events do not: they
    /// reach the process and its key window without a location.
    public let routedEventCount: Int

    /// The Window ID written into the routed events.
    public let windowNumber: Int

    /// The owning connection the window server reported for that window.
    public let ownerConnectionID: Int32

    public init(
        poster           : PostRoute,
        routedEventCount : Int,
        windowNumber     : Int,
        ownerConnectionID: Int32
    ) {
        self.poster            = poster
        self.routedEventCount  = routedEventCount
        self.windowNumber      = windowNumber
        self.ownerConnectionID = ownerConnectionID
    }
}
