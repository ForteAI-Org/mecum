//
//  ObservationUnavailable.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// ObservationCapability names one native ability the observation path needs.
///
/// A capability is available only where its evidence is. Compiling an adapter
/// for it proves nothing about the system it would run on, so an unqualified
/// capability produces a structured refusal before any effect instead of an
/// invented fact. Adding a case here is naming a gap, not closing one.
nonisolated public enum ObservationCapability: String, Sendable, Equatable {

    /// A Still of one attested window lifetime, qualified the same way a stream
    /// sample is.
    case windowStill

    /// A Still of the dedicated surface of a transient menu, attributed to the
    /// parent it was opened from. Not qualified: a filter aimed at a menu window
    /// has never been shown here to deliver that menu's pixels with usable
    /// geometry.
    case menuSurfaceStill

    /// An oracle that relates the sample's clock to the caller's, without which
    /// the age of the content stays unknown.
    case contentClock
}

/// ObservationUnavailable is why no observation was delivered.
///
/// It is answered instead of old pixels. There is no case that means "here is
/// the previous Frame": a consumer waiting for a new observation is told it is
/// waiting, and a Frame of the window before the change is never presented as
/// the current one.
nonisolated public enum ObservationUnavailable: Sendable, Equatable, Error {

    /// No application is assigned to this seat.
    case notAssigned

    /// No Selected Target to observe.
    case noSelectedTarget

    /// The target is selected and the seat may not act on it yet. The causes are
    /// carried whole and stay independent: resolving one says nothing about the
    /// others, and a Frame does not resolve any of them.
    case suspended([SeatSuspensionCause])

    /// A native ability this observation needs has no evidence on this system,
    /// so the operation is refused before any effect.
    case capabilityUnqualified(ObservationCapability)

    /// The capture answered, and what it answered is not sufficient evidence.
    case evidenceInsufficient(ObservedSampleEvidence)

    /// The whole capture budget passed. Attempts and queueing share one absolute
    /// deadline, so this is the end of the budget and not of one attempt. It does
    /// not prove that the native call stopped or that its resource is free.
    case captureDeadlineExpired(attemptsSpent: Int)

    /// The capture was refused or failed before any sample, with its reason as
    /// text for a report. It is not an incomplete reading: nothing was delivered.
    case captureFailed(reason: String)

    /// A menu interaction is current, so the target's own observation is not the
    /// one to take. The parent is carried for the report.
    case menuInteractionActive(parent: WindowIdentity)

    /// The menu interaction that scoped this observation is over, cancelled or
    /// expired.
    case menuContextRevoked
}
