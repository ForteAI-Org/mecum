//
//  ObservationIssuer.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics
import Synchronization

/// ObservationIssuerToken names the exact seat and lifecycle that issued an
/// Observation Reference.
///
/// The instance number is minted once per issuer from a process wide counter,
/// so two seats never share one and a value that outlived its seat matches
/// nothing. The lifecycle advances whenever the seat's assignment does, so a
/// reference from a previous assignment of the same seat is refused too.
///
/// It is public to read and impossible to construct from outside the package:
/// a consumer that could type one out would be granting itself the authority
/// this token exists to prove.
nonisolated public struct ObservationIssuerToken: Sendable, Equatable, Hashable {

    public let instanceNumber: UInt64
    public let lifecycle     : UInt64

    package init(instanceNumber: UInt64, lifecycle: UInt64) {
        self.instanceNumber = instanceNumber
        self.lifecycle      = lifecycle
    }
}

/// ObservationIssuer owns the observation half of one seat: which observation is
/// current, when it stopped being current, and whether a reference handed back
/// with a Command is still the one the kit issued.
///
/// ## Reference semantics on purpose
///
/// The barrier, the outstanding reference and the lifecycle have to be one
/// coordinated state for the length of a seat: a value copy would be a second
/// issuer that agrees with the first until the moment it matters. The seat owns
/// one and nothing else holds it.
///
/// ## What advances the barrier
///
/// A complete Command, a target or geometry change, a lifecycle end, a menu
/// opening or closing, and any other explicit invalidation. The barrier is what
/// makes "a new observation is needed after each Command" a check rather than a
/// convention, and it is deliberately not the selection generation: a selection
/// that did not move still needs a fresh observation after a Command.
///
/// ## What it does not do
///
/// It captures nothing, reads no clock of its own and never decides that
/// evidence is sufficient. It is handed facts and answers whether a reference
/// matches them.
package final class ObservationIssuer {

    private static let instanceCounter = Mutex<UInt64>(0)

    package let instanceNumber: UInt64

    /// Advances whenever the seat's assignment does, so observations do not
    /// survive a handover of another instance.
    package private(set) var lifecycle: UInt64 = 1

    /// Advances after every complete Command and on every invalidation.
    package private(set) var barrier: UInt64 = 1

    /// The one reference currently outstanding, nil when the seat is waiting for
    /// a new observation. One at a time is deliberate: a receiver holds at most
    /// one Frame, so holding a second reference would describe a Frame nobody
    /// has.
    package private(set) var outstanding: SeatObservationReference?

    /// Why the last invalidation happened, kept so a consumer asking afterwards
    /// is told the reason rather than "no observation".
    package private(set) var lastInvalidation: ObservationInvalidation?

    package init() {
        self.instanceNumber = Self.instanceCounter.withLock { counter in
            counter &+= 1
            return counter
        }
    }

    package var token: ObservationIssuerToken {
        ObservationIssuerToken(instanceNumber: instanceNumber, lifecycle: lifecycle)
    }

    /// Whether an observation is outstanding right now. It is a reading and not
    /// permission: the reference is still verified at admission.
    package var hasCurrentObservation: Bool { outstanding != nil }

    // MARK: Invalidation

    /// Drops the current observation and advances the barrier.
    ///
    /// It is immediate and unconditional, which is the contract: at a change of
    /// target the previous observation stops being authority before anything
    /// else is attempted, and no path exists that keeps the old pixels current
    /// while a new capture is arranged.
    package func invalidate(_ reason: ObservationInvalidation) {
        outstanding      = nil
        lastInvalidation = reason
        barrier        &+= 1
    }

    /// Ends the observation half of one assignment and opens the next lifecycle.
    /// Every reference of the previous lifecycle stops matching, whatever else
    /// about the world stayed the same.
    package func beginLifecycle() {
        lifecycle &+= 1
        invalidate(.lifecycleChanged)
    }

    /// Records that a Command completed, which requires a new observation before
    /// the next one. It is not an invalidation caused by a fault, so it keeps its
    /// own reason.
    package func noteCommandCompleted() {
        invalidate(.commandCompleted)
    }

    // MARK: Issuing

    /// Issues the reference for one delivered observation and makes it the
    /// current one.
    ///
    /// The caller supplies the facts; this type supplies the authority. Nothing
    /// here decides that the sample was good enough: a caller that has not
    /// qualified the evidence must not reach this method.
    package func issue(
        instance              : ProcessIdentity,
        surface               : WindowIdentity,
        selectionGeneration   : UInt64,
        geometryVersion       : GeometryObservationVersion,
        observedFrame         : CGRect,
        role                  : ObservedSurfaceRole,
        contentAge            : FrameContentAge,
        deliveredAtNanoseconds: UInt64
    ) -> SeatObservationReference {

        let reference = SeatObservationReference(
            issuer                : token,
            instance              : instance,
            surface               : surface,
            selectionGeneration   : selectionGeneration,
            geometryVersion       : geometryVersion,
            observedFrame         : observedFrame,
            role                  : role,
            barrier               : barrier,
            contentAge            : contentAge,
            deliveredAtNanoseconds: deliveredAtNanoseconds
        )
        outstanding      = reference
        lastInvalidation = nil
        return reference
    }

    // MARK: Admission

    /// Answers whether a reference handed back with a Command is still the one
    /// this issuer minted, for the situation described by `facts`.
    ///
    /// It is called at admission and again after every await that could have
    /// changed the world, up to the boundary before the first event. It never
    /// substitutes the current target for the reference's recipient: a Command
    /// addressed to a window the seat no longer considers current is refused,
    /// not redirected.
    package func admit(
        _ reference: SeatObservationReference,
        against facts: ObservationFacts,
        at now      : UInt64
    ) -> ObservationAdmissionRefusal? {

        guard reference.issuer == token else { return .foreignReference }
        guard let current = outstanding else {
            return .noCurrentObservation(lastInvalidation ?? .never)
        }
        guard current == reference        else { return .referenceSuperseded }
        guard reference.barrier == barrier else { return .barrierAdvanced }

        guard facts.instance == reference.instance else { return .instanceChanged }
        guard facts.surface  == reference.surface  else {
            return .recipientNotCurrent(reference.surface)
        }
        guard facts.selectionGeneration == reference.selectionGeneration else {
            return .selectionSuperseded(
                observed: reference.selectionGeneration,
                current : facts.selectionGeneration
            )
        }
        guard facts.role == reference.role else { return .roleChanged }
        guard facts.geometryVersion == reference.geometryVersion,
              VirtualWindowPlacementCheck.framesMatch(facts.observedFrame, reference.observedFrame)
        else { return .geometryChanged }

        let elapsed = Int64(bitPattern: now &- reference.deliveredAtNanoseconds)
        switch reference.contentAge.advanced(byNanoseconds: elapsed) {

            case .unknown(let doubt):
                return .frameAgeUnknown(doubt)

            case .qualified(let nanoseconds):
                guard nanoseconds <= facts.frameAgeLimitNanoseconds else {
                    return .frameTooOld(
                        ageNanoseconds  : nanoseconds,
                        limitNanoseconds: facts.frameAgeLimitNanoseconds
                    )
                }
                return nil
        }
    }
}
