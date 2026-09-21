//
//  AgentSeat+Observation.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics
import Dispatch
import os
import SeatCapture
import SeatCore

/// MenuContext is the interaction currently scoping what the seat may send: the
/// parent it belongs to, the menu surface it observes, the generation that makes
/// a kept reference stale, and the absolute instant its budget ends at.
///
/// It is a value held by the seat and never handed out. The consumer holds a
/// `SeatMenuInteraction`, which carries only a generation and asks the seat.
nonisolated struct MenuContext {

    let generation     : UInt64
    let parent         : WindowIdentity
    let parentReference: WindowReference
    let menu           : ContextMenu
    let menuIdentity   : WindowIdentity

    /// The marker of the Turn that opened the interaction. Every Command inside
    /// the menu is stamped with it, because a menu Command belongs to the hold
    /// that opened the menu and never to a new one.
    let correlationID: Int64

    /// The absolute monotonic instant the 180 s interaction budget ends at.
    let deadlineNanoseconds: UInt64

    /// What the interaction posted inside the menu, in order. Preserved so an
    /// outcome carries what went out even when a later step failed.
    var receipts: [InputReceipt] = []
}

// MARK: - Assignment and selection, composed rather than modelled again

extension AgentSeat {

    static let observationLog = Logger(
        subsystem: "dev.forte.AgentSeatKit",
        category : "Observation"
    )

    /// Hands the window's instance over to the assignment nucleus the first time
    /// the seat drives it.
    ///
    /// The attestation is `windowServerAttested` because the reference reached
    /// here only through `checkIdentityIsAttested`, which refuses a raw PID and
    /// Window ID. A second window of the same instance changes nothing; a window
    /// of a different instance is refused by the lifecycle, which is what keeps
    /// one seat to one entrusted application.
    func takeOverInstance(of window: WindowReference) {

        guard let identity = window.identity else { return }
        guard !assignmentKit.lifecycle.isAssigned else { return }

        let outcome = assignmentKit.handOver(
            instance   : identity.process,
            attestation: .windowServerAttested,
            at         : DispatchTime.now().uptimeNanoseconds
        )
        if case .failure(let refusal) = outcome {
            AgentSeat.observationLog.error("""
                the assignment refused the handover: \(refusal.rawValue, privacy: .public)
                """)
            return
        }
        observationIssuer.beginLifecycle()
    }

    /// Folds one reading of the assigned instance's surfaces through both nuclei.
    ///
    /// It is called where the seat already takes readings: after an adoption, at
    /// a target transfer, and before an observation. Two folds that agree are
    /// what verify a surface, which is why the observation path folds again
    /// rather than trusting the fold the adoption made.
    func foldCurrentReading(at now: UInt64 = DispatchTime.now().uptimeNanoseconds) {

        guard assignmentKit.lifecycle.isAssigned else { return }
        let reading = surfaceReader.read(ownedBy: session.processIDs)
        let claims  = surfaceReader.selectionClaims(for: reading)

        selectionKit.ingest(
            reading,
            within  : sensing.virtualDisplayBounds,
            displays: [:],
            at      : now
        )
        for claim in claims.roles        { selectionKit.declareRole(claim) }
        for claim in claims.parents      { selectionKit.declareParent(claim) }
        for claim in claims.modals       { selectionKit.declareModal(claim) }
        for claim in claims.visibilities { selectionKit.observeVisibility(claim) }
        for claim in claims.recency      { selectionKit.noteRecency(claim) }
    }

    /// Folds one more reading through both nuclei on request.
    ///
    /// The seat folds where it already takes readings, and a surface needs two
    /// agreeing readings before it is verified. This is the explicit way to take
    /// one more, for an owner that knows the world has settled and does not want
    /// to wait for the next natural fold.
    package func refreshTargetReadings() {
        foldCurrentReading()
        publishCoherentState()
    }

    /// Asks the selection nucleus for this surface explicitly, which is what a
    /// consumer's own target change is. A refusal is reported through the causes
    /// of the gate and never worked around here.
    func selectExplicitly(_ window: WindowReference) {
        guard let identity = window.identity else { return }
        foldCurrentReading()
        if case .failure(let refusal) = selectionKit.selectExplicitly(identity) {
            AgentSeat.observationLog.info("""
                the explicit selection was refused: \(String(describing: refusal), privacy: .public)
                """)
        }
    }

    /// Records that a surface the seat held is gone, on the seat's own proof of
    /// it: an explicit release or a destruction the recovery established. An
    /// absence from a reading is not this, and does not reach here.
    func noteSurfaceGone(_ windowNumber: Int) {
        selectionKit.confirmClosure(
            of      : windowNumber,
            evidence: .windowServerConfirmedDestruction
        )
        observationIssuer.invalidate(.targetChanged)
        outstandingGeometry = nil
    }

    /// Ends the assignment and the observation half together. Input authority
    /// goes first, before any window moves, and the restitution the release left
    /// behind stays an explicit obligation rather than a success.
    func endAssignmentAndObservation(reason: ObservationInvalidation) {
        guard assignmentKit.lifecycle.isAssigned else {
            observationIssuer.invalidate(reason)
            outstandingGeometry = nil
            return
        }
        _ = assignmentKit.release()
        observationIssuer.invalidate(reason)
        outstandingGeometry = nil
        menuContext = nil
    }
}

// MARK: - Observing

extension AgentSeat {

    /// Observes the Selected Target and hands back the Frame with the
    /// Observation Reference that binds it.
    ///
    /// ## What it refuses, and what it never does
    ///
    /// It answers an unavailability with its reason and never answers old pixels.
    /// There is no path here that returns the previous Frame, the parent's Frame
    /// during a menu interaction, or a placeholder: a consumer waiting for a new
    /// observation is told that it is waiting.
    ///
    /// ## The budget
    ///
    /// One request has 5 s in total and at most 2 attempts, and they share that
    /// one absolute deadline: the second attempt does not restart it. Reaching
    /// the deadline is an explicit expiry carrying the attempts spent. It does
    /// not prove the native call stopped, and it never declares a capture slot
    /// free.
    ///
    /// ## After every await
    ///
    /// The selection, the assignment and the menu state are read again when the
    /// capture returns. A result that arrived after the target moved is dropped
    /// rather than issued: a late capture of the previous selection is not an
    /// observation of the current one.
    public func observe() async -> Result<SeatObservationDelivery, ObservationUnavailable> {

        if let context = menuContext {
            return .failure(.menuInteractionActive(parent: context.parent))
        }
        foldCurrentReading()

        guard let assignment = assignmentKit.lifecycle.current else {
            return .failure(.notAssigned)
        }
        let operability = selectionKit.operability()
        guard let selected = selectionKit.selected else {
            if case .suspended(_, let causes) = operability, !causes.isEmpty {
                return .failure(.suspended(causes.map(SeatSuspensionCause.init)))
            }
            return .failure(.noSelectedTarget)
        }
        guard !monitorHealth.blocksInput else {
            return .failure(.suspended([.monitorSharedFault]))
        }
        // Every cause except the missing observation has to be clear. The
        // missing observation is precisely what this call answers, and it is the
        // automatic Still of ASI-D-023: identity and containment first, the
        // Frame after them.
        var causes: [SelectionSuspension] = []
        if case .suspended(_, let reported) = operability {
            causes = reported.filter { $0 != .observationMissing }
        }
        guard causes.isEmpty else {
            return .failure(.suspended(causes.map(SeatSuspensionCause.init)))
        }

        guard observationSource.supports(.windowStill) else {
            return .failure(.capabilityUnqualified(.windowStill))
        }
        return await captureAndIssue(
            surface            : selected.surface,
            role               : .ordinaryTarget,
            instance           : assignment.instance,
            selectionGeneration: selected.generation,
            deadlineNanoseconds: DispatchTime.now().uptimeNanoseconds
                &+ observationProfile.captureDeadlineNanoseconds,
            isMenu             : false
        )
    }

    /// True while this generation is the interaction the seat is scoping by.
    func menuContextIsCurrent(_ generation: UInt64) -> Bool {
        guard let context = menuContext, context.generation == generation else { return false }
        return DispatchTime.now().uptimeNanoseconds < context.deadlineNanoseconds
    }

    /// Observes the dedicated surface of the current menu interaction.
    ///
    /// The capture budget is the tighter of the 5 s request budget and what is
    /// left of the 180 s interaction, and neither of them is renewed by this
    /// call. On this build the source does not support the capability, so the
    /// refusal is the answer.
    func observeMenuSurface(
        generation: UInt64
    ) async -> Result<SeatObservationDelivery, ObservationUnavailable> {

        guard menuContextIsCurrent(generation), let context = menuContext,
              let assignment = assignmentKit.lifecycle.current
        else { return .failure(.menuContextRevoked) }

        guard observationSource.supports(.menuSurfaceStill) else {
            return .failure(.capabilityUnqualified(.menuSurfaceStill))
        }
        let requestDeadline = DispatchTime.now().uptimeNanoseconds
            &+ observationProfile.captureDeadlineNanoseconds

        return await captureAndIssue(
            surface            : context.menuIdentity,
            role               : .transientMenu(parent: context.parent),
            instance           : assignment.instance,
            selectionGeneration: selectionKit.selectionGeneration,
            deadlineNanoseconds: min(requestDeadline, context.deadlineNanoseconds),
            isMenu             : true
        )
    }

    /// The attempt loop, the qualification and the issuing, shared by the two
    /// observation paths because their budget and their invalidation rules are
    /// the same.
    private func captureAndIssue(
        surface            : WindowIdentity,
        role               : ObservedSurfaceRole,
        instance           : ProcessIdentity,
        selectionGeneration: UInt64,
        deadlineNanoseconds: UInt64,
        isMenu             : Bool
    ) async -> Result<SeatObservationDelivery, ObservationUnavailable> {

        let barrier = observationIssuer.barrier
        var attempts = 0
        var lastFailure: ObservationUnavailable = .captureDeadlineExpired(attemptsSpent: 0)

        while attempts < observationProfile.captureAttempts {
            guard DispatchTime.now().uptimeNanoseconds < deadlineNanoseconds else {
                return .failure(.captureDeadlineExpired(attemptsSpent: attempts))
            }
            attempts += 1

            let frame: SeatFrame
            do {
                if isMenu {
                    frame = try await observationSource.captureMenuStill(
                        of                 : surface,
                        parent             : role.parent ?? surface,
                        observationBarrier : barrier,
                        deadlineNanoseconds: deadlineNanoseconds
                    )
                } else {
                    frame = try await observationSource.captureWindowStill(
                        of                 : surface,
                        observationBarrier : barrier,
                        deadlineNanoseconds: deadlineNanoseconds
                    )
                }
            } catch let unavailable as ObservationUnavailable {
                if case .capabilityUnqualified = unavailable { return .failure(unavailable) }
                lastFailure = unavailable
                continue
            } catch {
                lastFailure = .captureFailed(reason: String(describing: error))
                continue
            }

            let arrivedAt = DispatchTime.now().uptimeNanoseconds

            // Read again after the await. A capture that came back after the
            // target moved, the assignment ended or the menu was revoked is a
            // result of a situation that no longer exists.
            if let refusal = stillCurrent(
                surface            : surface,
                role               : role,
                instance           : instance,
                selectionGeneration: selectionGeneration,
                barrier            : barrier,
                isMenu             : isMenu
            ) {
                return .failure(refusal)
            }

            switch sampleQualifier.qualify(frame, of: surface, atNanoseconds: arrivedAt) {

                case .failure(let evidence):
                    // Delivered and not good enough. Retrying would ask the same
                    // question of the same evidence, so the answer is given now.
                    return .failure(.evidenceInsufficient(evidence))

                case .success(let qualified):
                    let reference = observationIssuer.issue(
                        instance              : instance,
                        surface               : surface,
                        selectionGeneration   : selectionGeneration,
                        geometryVersion       : qualified.geometry.version,
                        observedFrame         : qualified.geometry.window.frame,
                        role                  : role,
                        contentAge            : qualified.contentAge,
                        deliveredAtNanoseconds: arrivedAt
                    )
                    outstandingGeometry = qualified.geometry
                    publishCoherentState()
                    return .success(
                        SeatObservationDelivery(
                            frame    : qualified.frame,
                            reference: reference,
                            geometry : qualified.geometry
                        )
                    )
            }
        }
        return .failure(lastFailure)
    }

    /// Whether the situation the capture was started in is still the situation
    /// now, answered as the unavailability to report when it is not.
    private func stillCurrent(
        surface            : WindowIdentity,
        role               : ObservedSurfaceRole,
        instance           : ProcessIdentity,
        selectionGeneration: UInt64,
        barrier            : UInt64,
        isMenu             : Bool
    ) -> ObservationUnavailable? {

        guard !isTearingDown, state != .failed else { return .notAssigned }
        guard let assignment = assignmentKit.lifecycle.current,
              assignment.instance == instance
        else { return .notAssigned }
        guard observationIssuer.barrier == barrier else {
            return .suspended([.observationSuperseded(
                observed: selectionGeneration,
                current : selectionKit.selectionGeneration
            )])
        }
        guard isMenu else {
            foldCurrentReading()
            guard let selected = selectionKit.selected, selected.surface == surface,
                  selected.generation == selectionGeneration
            else {
                return .suspended([.observationSuperseded(
                    observed: selectionGeneration,
                    current : selectionKit.selectionGeneration
                )])
            }
            return nil
        }
        // A menu result that came back after the interaction was revoked has no
        // authority: the callback succeeding does not restore the context.
        guard let context = menuContext, context.menuIdentity == surface,
              context.parent == role.parent,
              DispatchTime.now().uptimeNanoseconds < context.deadlineNanoseconds
        else { return .menuContextRevoked }
        return nil
    }
}

// MARK: - Admitting a Command

extension AgentSeat {

    /// Admits an ordinary Command's reference and answers the Adopted Window it
    /// is addressed to.
    ///
    /// The recipient comes from the reference and from nowhere else. A seat whose
    /// target moved refuses; it does not deliver the Command to whatever is
    /// current now.
    func admitOrdinary(_ reference: SeatObservationReference) throws -> AdoptedWindow {

        if let refusal = admissionRefusal(for: reference, expecting: .ordinaryTarget) {
            throw refusal
        }
        guard let record = session[reference.recipient.windowNumber],
              record.window.reference.identity == reference.recipient
        else { throw ObservationAdmissionRefusal.recipientNotCurrent(reference.recipient) }
        return record.window
    }

    /// The reason this reference may not be acted on right now, nil when it may.
    ///
    /// It gathers the live facts into one value first, so the whole verdict
    /// belongs to one instant rather than to four readings taken while the checks
    /// ran, and hands them to the issuer, which owns the comparison.
    func admissionRefusal(
        for reference: SeatObservationReference,
        expecting role: ObservedSurfaceRole
    ) -> ObservationAdmissionRefusal? {

        // Who issued it comes first. A value from another seat, from another
        // lifecycle of this seat, or one a consumer assembled is answered as
        // what it is, rather than as whatever the current state happens to be.
        guard reference.issuer == observationIssuer.token else { return .foreignReference }

        guard let assignment = assignmentKit.lifecycle.current else {
            return .instanceChanged
        }
        guard let geometry = outstandingGeometry else {
            return .noCurrentObservation(observationIssuer.lastInvalidation ?? .never)
        }
        guard reference.role == role else {
            if case .transientMenu(let parent) = reference.role {
                return .ordinaryCommandDuringMenu(parent: parent)
            }
            return .roleChanged
        }

        let liveSurface     : WindowIdentity
        let selectionMoment : UInt64

        switch role {
            case .ordinaryTarget:
                guard let selected = selectionKit.selected else {
                    return .recipientNotCurrent(reference.recipient)
                }
                liveSurface     = selected.surface
                selectionMoment = selected.generation

            case .transientMenu:
                guard let context = menuContext,
                      DispatchTime.now().uptimeNanoseconds < context.deadlineNanoseconds
                else { return .menuContextRevoked }
                liveSurface     = context.menuIdentity
                selectionMoment = selectionKit.selectionGeneration
        }

        guard let reading = sensing.windowGeometry(of: liveSurface.windowNumber),
              reading.identity == liveSurface
        else { return .geometryChanged }

        let facts = ObservationFacts(
            instance                : assignment.instance,
            surface                 : liveSurface,
            selectionGeneration     : selectionMoment,
            geometryVersion         : geometry.version,
            observedFrame           : reading.frame,
            role                    : role,
            frameAgeLimitNanoseconds: observationProfile.frameAgeLimitNanoseconds
        )
        return observationIssuer.admit(
            reference,
            against: facts,
            at     : DispatchTime.now().uptimeNanoseconds
        )
    }

    /// Records that a complete Command spent the current observation. The next
    /// Command needs a new one, and the barrier is what makes that a check.
    func noteObservationConsumed() {
        observationIssuer.noteCommandCompleted()
        outstandingGeometry = nil
        publishCoherentState()
    }
}

// MARK: - The coherent state

extension AgentSeat {

    /// The current reading of everything a consumer shows and decides with.
    ///
    /// Reading it grants nothing: a Command is still checked against its
    /// Observation Reference and against the gate where input is admitted,
    /// however recently this said the target was operational.
    public var coherentState: SeatCoherentState {
        let operability = selectionKit.operability()
        var operational : WindowIdentity?
        var suspensions : [SeatSuspensionCause] = []

        switch operability {
            case .operational(let target):  operational = target.surface
            case .suspended(_, let causes): suspensions = causes.map(SeatSuspensionCause.init)
        }
        if monitorHealth.blocksInput { suspensions.append(.monitorSharedFault) }

        return SeatCoherentState(
            revision             : stateRevision,
            lifecycle            : observationIssuer.lifecycle,
            instance             : assignmentKit.lifecycle.current?.instance,
            selectedTarget       : selectionKit.selected?.surface,
            operationalTarget    : monitorHealth.blocksInput ? nil : operational,
            suspensions          : suspensions,
            hasCurrentObservation: observationIssuer.hasCurrentObservation,
            lastInvalidation     : observationIssuer.lastInvalidation,
            observedRole         : observationIssuer.outstanding?.role,
            monitor              : monitorHealth,
            outstandingReturns   : assignmentKit.restitution.outstanding
        )
    }

    /// Registers a consumer and hands it the reading its updates continue from,
    /// in the same main actor turn, so no change falls between the two.
    public func subscribeToState() -> SeatStateSubscription {
        let subscription = SeatStateSubscription(current: coherentState) { [weak self] ended in
            self?.stateSubscribers[ObjectIdentifier(ended)] = nil
        }
        stateSubscribers[ObjectIdentifier(subscription)] = subscription
        return subscription
    }

    /// Records the Monitor's own health, which the host that owns the Monitor
    /// reports. An isolated fault leaves valid input working and is published so
    /// the consumer can mark the last image stale; a shared fault also closes the
    /// gate, because then the capture the observation needs is gone too.
    public func reportMonitorHealth(_ health: SeatMonitorHealth) {
        guard monitorHealth != health else { return }
        monitorHealth = health
        if health.blocksInput {
            observationIssuer.invalidate(.suspensionRaised)
            outstandingGeometry = nil
        }
        publishCoherentState()
    }

    /// Publishes one newer revision to every registered consumer.
    ///
    /// The buffer keeps the newest values only, so a slow consumer cannot make
    /// the seat accumulate snapshots or hold up the focus path; every value is a
    /// whole state, so a consumer that missed some still reconstructs the current
    /// one from the next.
    func publishCoherentState() {
        stateRevision &+= 1
        let state = coherentState
        for subscription in stateSubscribers.values { subscription.publish(state) }
    }
}
