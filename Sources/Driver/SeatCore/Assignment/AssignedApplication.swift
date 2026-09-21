//
//  AssignedApplication.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// InstanceAttestation says how the identity of an application instance was
/// established, so that the decision to take it into the Agent Seat is taken on
/// evidence rather than on a number. A PID is handed out again after the process
/// that carried it terminated, and a window title is written by the application
/// itself, so neither of them authorizes an assignment on its own.
nonisolated package enum InstanceAttestation: String, Sendable, Equatable {

    /// The process serial number came from the WindowServer connection that owns
    /// the application's windows and resolved back to this PID.
    case windowServerAttested

    /// A PID, and nothing that binds it to one process lifetime.
    case processIdentifierOnly

    /// A value assembled from a title, a bundle identifier or a launch that was
    /// never observed through the window server.
    case unverified

    /// Only an attested identity may be handed over. It is written as a property
    /// rather than compared at every call site so the rule has one place.
    package var authorisesAssignment: Bool { self == .windowServerAttested }
}

/// AssignedApplication is one application instance entrusted as a whole to an
/// Agent Seat: the attested lifetime of its process, the generation of this
/// assignment, and when the handover started.
///
/// The generation is what separates two assignments of the same application. A
/// consumer that restarts the application and gets the same PID back receives a
/// different `ProcessIdentity`, so `authorises` answers false and the consumer
/// has to hand the new instance over explicitly.
nonisolated package struct AssignedApplication: Sendable, Equatable {

    package let instance: ProcessIdentity

    /// Counts assignments of this lifecycle, starting at one. It is carried so
    /// that a record produced under an earlier assignment can be told from one
    /// produced under the current one.
    package let generation: UInt64

    /// When the handover began, on the caller's monotonic clock. The initial
    /// containment deadline is measured from here and never restarted.
    package let handoverStartedAtNanoseconds: UInt64

    package init(
        instance                    : ProcessIdentity,
        generation                  : UInt64,
        handoverStartedAtNanoseconds: UInt64
    ) {
        self.instance                     = instance
        self.generation                   = generation
        self.handoverStartedAtNanoseconds = handoverStartedAtNanoseconds
    }

    /// True only for the whole attested lifetime this assignment was given. The
    /// comparison is on `ProcessIdentity` and never on `processID`, which is the
    /// one line that keeps a reused PID from inheriting an authorization.
    package func authorises(_ instance: ProcessIdentity) -> Bool {
        self.instance == instance
    }
}

/// AssignmentEnd is one of the three ways an assignment stops. The set is closed
/// on purpose: the end of a Turn and the last window closing are not in it.
nonisolated package enum AssignmentEnd: String, Sendable, Equatable {

    /// The consumer gave the application back.
    case explicitRelease

    /// The assigned instance terminated. A later instance of the same
    /// application is a new assignment, not the continuation of this one.
    case instanceExited

    /// The Seat itself stopped, which ends every assignment it held.
    case seatStopped
}

/// AssignmentRefusal is a rejection taken before any effect: nothing was moved,
/// nothing was suspended, and the consumer can act on the reason.
nonisolated package enum AssignmentRefusal: String, Sendable, Equatable, Error {

    /// The identity offered is a PID, a title or an unverified value.
    case identityNotAttested

    /// Another instance is already assigned to this seat. The consumer releases
    /// it explicitly before handing over a second one.
    case anotherInstanceAssigned

    /// The seat is stopped, so there is nothing to hand an application to.
    case seatStopped
}

/// AssignmentLifecycle owns the answer to "is this instance still entrusted to
/// the agent", and nothing else: it holds no window, performs no reading and
/// makes no system call.
///
/// ## What does not end an assignment
///
/// Neither the end of a Turn nor an application with no open windows ends it.
/// Both were tempting because they are visible, and both are wrong: a Turn is
/// exclusive use between two safe points, and an application between two
/// documents legitimately has nothing on screen. The assignment ends only on the
/// three `AssignmentEnd` cases, and a restarted application has to be handed
/// over again because its attested lifetime is a different one.
nonisolated package struct AssignmentLifecycle: Sendable {

    package private(set) var current: AssignedApplication?

    /// Why the last assignment ended, kept after the end so that a consumer
    /// asking a moment later is told the reason instead of "nothing assigned".
    package private(set) var lastEnd: AssignmentEnd?

    package private(set) var generation: UInt64 = 0

    /// Terminal once true: a stopped seat refuses every later handover.
    package private(set) var isSeatStopped = false

    package init() {}

    package var isAssigned: Bool { current != nil }

    /// Takes an explicitly handed over instance into the seat, or refuses before
    /// any effect. An unattested identity is refused here rather than deep in a
    /// containment pass, where a refusal would already have moved windows.
    package mutating func accept(
        instance   : ProcessIdentity,
        attestation: InstanceAttestation,
        at now     : UInt64
    ) -> Result<AssignedApplication, AssignmentRefusal> {

        guard !isSeatStopped                   else { return .failure(.seatStopped) }
        guard attestation.authorisesAssignment else { return .failure(.identityNotAttested) }
        guard current == nil                   else { return .failure(.anotherInstanceAssigned) }

        generation &+= 1
        let assignment = AssignedApplication(
            instance                    : instance,
            generation                  : generation,
            handoverStartedAtNanoseconds: now
        )
        current = assignment
        lastEnd = nil
        return .success(assignment)
    }

    /// True while this exact attested lifetime is the assigned one. It is the
    /// only question the rest of the kit should ask about membership of a
    /// process, because it is the only one a reused PID cannot answer yes to.
    package func authorises(_ instance: ProcessIdentity) -> Bool {
        current?.authorises(instance) == true
    }

    /// Ends the assignment explicitly. Answers what ended, or nil when there was
    /// nothing assigned, so a double release is visible instead of silent.
    @discardableResult
    package mutating func release(reason: AssignmentEnd = .explicitRelease) -> AssignedApplication? {
        guard let ended = current else { return nil }
        current = nil
        lastEnd = reason
        return ended
    }

    /// Ends the assignment when the exited instance is the assigned one. An exit
    /// reported for a different lifetime changes nothing: that is the process
    /// that used to carry the PID, not the one being driven.
    @discardableResult
    package mutating func noteExit(of instance: ProcessIdentity) -> AssignedApplication? {
        guard current?.authorises(instance) == true else { return nil }
        return release(reason: .instanceExited)
    }

    /// Stops the seat. Every later handover is refused, which is what makes a
    /// stop terminal rather than a pause.
    @discardableResult
    package mutating func stopSeat() -> AssignedApplication? {
        isSeatStopped = true
        return release(reason: .seatStopped)
    }
}
