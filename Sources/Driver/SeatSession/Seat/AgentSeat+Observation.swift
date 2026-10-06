//
//  AgentSeat+Observation.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import ApplicationServices
import AppKit
import CoreGraphics
import Dispatch
import os
import SeatCapture
import SeatCore
import SeatInput
import WindowPlacement

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

/// The explicitly attested family ScreenCaptureKit must composite for a hosted
/// sheet. `surface` remains the host identity, while `screenRect` is the exact
/// crop used for pixel-to-screen mapping.
nonisolated private struct HostedCaptureRegion: Equatable {
    let host: WindowIdentity
    let children: [WindowIdentity]
    let screenRect: CGRect
    let sourceWindowFrame: CGRect
}

/// The current scoped lifetime evidence for a logical surface. A remote helper
/// may deliberately remain in WindowServer after its AppKit panel has closed,
/// so callers deciding a dialog outcome must use this witness before treating
/// public WindowServer absence as a closure.
public enum LogicalSurfacePresence: Sendable, Equatable {
    case present
    case withdrawn
    case destroyed
    case replaced
    case unreadable
}

/// EndpointDiscovery is the two readings the seat needs to address a Command at
/// a window it holds no record for: the descent that finds the recipient, and
/// the window server identity that says the recipient is still the same one.
///
/// It is one injected value because both readings are of the live system and
/// neither can be composed in the Unit tier: there is no panel on the screen to
/// descend and no window server row to read. A suite substitutes the decision
/// the readings would have reached, which is what makes the whole routing table
/// provable without a window.
@MainActor
struct EndpointDiscovery {

    var pointer: (
        _ assignedProcessID  : Int32,
        _ point              : CGPoint,
        _ chain              : DialogEndpointResolver<AXUIElement>.SurfaceChain,
        _ selectionGeneration: UInt64
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal>

    /// The keyboard's reading, which takes no point: it descends from the
    /// application's focused node and not from anywhere the pointer has been.
    var keyboardContext: (
        _ assignedProcessID  : Int32,
        _ chain              : DialogEndpointResolver<AXUIElement>.SurfaceChain,
        _ selectionGeneration: UInt64
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal>

    var identity: (Int) -> WindowIdentity?

    /// The window the internal focus is in at the boundary, which is what
    /// retires a keyboard context whose focus moved.
    var focusedWindowNumber: (Int32) -> Int?

    /// A remote WindowServer owner may use the AppKit panel recipe only when it
    /// identifies as the platform panel service. A distinct PID establishes a
    /// transport relation, not a backend or an input capability.
    var qualifiedAppKitPanelService: (WindowIdentity) -> Bool = { _ in false }

    /// Window-level keys need no focused control when a complete reading proves
    /// that the selected ordinary window has no foreign content underneath it.
    var ordinaryKeyboardContext: (
        Int32, DialogEndpointResolver<AXUIElement>.SurfaceChain, UInt64
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal> = { _, chain, _ in
        .failure(.subtreeUnreadable(surface: chain.surface))
    }

    /// Only selected UXP documents may use the main window beneath a
    /// positively empty, nonmodal accessibility focus proxy.
    var mainWindowUnderFocusProxyKeyboardContext: (
        Int32, DialogEndpointResolver<AXUIElement>.SurfaceChain, UInt64
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal> = { _, chain, _ in
        .failure(.subtreeUnreadable(surface: chain.surface))
    }

    /// A modal proxy may expose focus only on its descendants. The complete
    /// scoped reading must identify one keyboard window before it can be used.
    var focusedDescendantKeyboardContext: (
        Int32, DialogEndpointResolver<AXUIElement>.SurfaceChain, UInt64
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal> = { _, chain, _ in
        .failure(.subtreeUnreadable(surface: chain.surface))
    }

    /// A modal that is its own window and a single accessibility leaf is its
    /// own recipient, which is the last reading a modal's refusal gets.
    var leafSurface: (
        Int32, InputEndpointKind, DialogEndpointResolver<AXUIElement>.SurfaceChain, UInt64
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal> = { _, _, chain, _ in
        .failure(.subtreeUnreadable(surface: chain.surface))
    }

    /// A top-level UXP modal's complete own-window subtree can qualify the
    /// modal as a keyboard destination to prepare despite stale document focus.
    var modalSurfaceKeyboardContext: (
        Int32, DialogEndpointResolver<AXUIElement>.SurfaceChain, UInt64
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal> = { _, chain, _ in
        .failure(.subtreeUnreadable(surface: chain.surface))
    }

    /// A modal whose focus cannot be read takes keys in the one remote content
    /// window of another process its descendants name.
    var remoteContentKeyboardContext: (
        Int32, DialogEndpointResolver<AXUIElement>.SurfaceChain, UInt64
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal> = { _, chain, _ in
        .failure(.subtreeUnreadable(surface: chain.surface))
    }

    /// A modal whose focus reads as its own window node takes keys in its one
    /// foreign content window when a descendant there is focused.
    var focusedContentKeyboardContext: (
        Int32, DialogEndpointResolver<AXUIElement>.SurfaceChain, UInt64
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal> = { _, chain, _ in
        .failure(.subtreeUnreadable(surface: chain.surface))
    }

    /// The one window of another process drawn over a modal surface, read
    /// without any focus: what says whose panel the surface is.
    var foreignContentWindow: (
        Int32, DialogEndpointResolver<AXUIElement>.SurfaceChain
    ) -> Int? = { _, _ in nil }

    /// An ordinary window's own content with no Window ID, such as a web page,
    /// takes its events itself: a point is proved from the node under it, no
    /// point from the focused control. Asked only without a modal relation.
    var windowlessContent: (
        Int32, CGPoint?, DialogEndpointResolver<AXUIElement>.SurfaceChain, UInt64
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal> = { _, _, chain, _ in
        .failure(.subtreeUnreadable(surface: chain.surface))
    }

    /// The applications whose ordinary windows take their clicks through
    /// accessibility, as a remote panel's content does (ADR 0031). The one
    /// place this scope is decided; add a bundle identifier to widen it.
    static let accessibilityClickedApplications: Set<String> = ["com.apple.finder"]

    /// Whether `window` belongs to one of `accessibilityClickedApplications`.
    var clicksThroughAccessibility: (WindowIdentity) -> Bool = { _ in false }

    /// A click on a qualified remote panel's content, acted on through the
    /// assigned application's accessibility instead of posted (ADR 0031).
    var remoteActuation: (
        Int32, InputCommand, ResolvedInputEndpoint
    ) -> Result<RemoteContentActuation, RemoteContentActuationRefusal> = { _, _, _ in
        .failure(.unreadable)
    }

    /// The readings the shipping seat takes.
    static let shipping = EndpointDiscovery(
        pointer: { processID, point, chain, generation in
            DialogEndpointResolver<AXUIElement>
                .accessibility(assignedProcessID: processID)
                .pointerEndpoint(at: point, within: chain, selectionGeneration: generation)
        },
        keyboardContext: { processID, chain, generation in
            DialogEndpointResolver<AXUIElement>
                .accessibility(assignedProcessID: processID)
                .keyboardContext(within: chain, selectionGeneration: generation)
        },
        identity: { WindowServerProbe.identity(of: $0) },
        focusedWindowNumber: {
            DialogEndpointResolver<AXUIElement>
                .accessibility(assignedProcessID: $0)
                .focusedNodeWindowNumber()
        },
        qualifiedAppKitPanelService: { identity in
            NSRunningApplication(processIdentifier: pid_t(identity.processID))?.bundleIdentifier
                == "com.apple.appkit.xpc.openAndSavePanelService"
        },
        ordinaryKeyboardContext: { processID, chain, generation in
            DialogEndpointResolver<AXUIElement>
                .accessibility(assignedProcessID: processID)
                .ordinaryKeyboardContext(within: chain, selectionGeneration: generation)
        },
        mainWindowUnderFocusProxyKeyboardContext: { processID, chain, generation in
            DialogEndpointResolver<AXUIElement>
                .accessibility(assignedProcessID: processID)
                .mainWindowUnderFocusProxyKeyboardContext(within: chain, selectionGeneration: generation)
        },
        focusedDescendantKeyboardContext: { processID, chain, generation in
            DialogEndpointResolver<AXUIElement>
                .accessibility(assignedProcessID: processID)
                .focusedDescendantKeyboardContext(within: chain, selectionGeneration: generation)
        },
        leafSurface: { processID, kind, chain, generation in
            DialogEndpointResolver<AXUIElement>
                .accessibility(assignedProcessID: processID)
                .leafSurfaceEndpoint(kind: kind, within: chain, selectionGeneration: generation)
        },
        modalSurfaceKeyboardContext: { processID, chain, generation in
            DialogEndpointResolver<AXUIElement>
                .accessibility(assignedProcessID: processID)
                .modalSurfaceKeyboardContext(within: chain, selectionGeneration: generation)
        },
        remoteContentKeyboardContext: { processID, chain, generation in
            DialogEndpointResolver<AXUIElement>
                .accessibility(assignedProcessID: processID)
                .remoteContentKeyboardContext(within: chain, selectionGeneration: generation)
        },
        focusedContentKeyboardContext: { processID, chain, generation in
            DialogEndpointResolver<AXUIElement>
                .accessibility(assignedProcessID: processID)
                .focusedContentKeyboardContext(within: chain, selectionGeneration: generation)
        },
        foreignContentWindow: { processID, chain in
            DialogEndpointResolver<AXUIElement>
                .accessibility(assignedProcessID: processID)
                .foreignContentWindow(within: chain)
        },
        windowlessContent: { processID, point, chain, generation in
            DialogEndpointResolver<AXUIElement>
                .accessibility(assignedProcessID: processID)
                .windowlessContentEndpoint(at: point, within: chain, selectionGeneration: generation)
        },
        clicksThroughAccessibility: { window in
            NSRunningApplication(processIdentifier: pid_t(window.processID))?.bundleIdentifier
                .map(accessibilityClickedApplications.contains) ?? false
        },
        remoteActuation: { processID, command, endpoint in
            RemoteContentActuator<AXUIElement>
                .accessibility(assignedProcessID: processID)
                .actuate(command, endpoint: endpoint)
        }
    )
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
    ///
    /// One at a time and not one ever: the consumer gives the instance back with
    /// `releaseAssignedApplication`, and the next window handed over here opens
    /// the next assignment under the next generation.
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

    /// Takes one reading of the assigned instance's surfaces and keeps the one
    /// piece of it no later reading can restate.
    ///
    /// A destruction proof is one-shot. The reader names a retained identity to
    /// the window server exactly once, and the transition filter drops the
    /// identity the moment an answer comes back destroyed, so every pass after
    /// it is silent about the window. Whichever of the seat's readers happened
    /// to take that pass is therefore the only one that will ever see it, and
    /// two of the three, the presence probe the closure transition makes and
    /// the reconciliation before a release, do not end containment waits. Every
    /// reading goes through here so the proof is remembered for the fold that
    /// does, instead of depending on which caller polled first.
    func readSurfaces() -> AssignedSurfaceSnapshot {

        let snapshot = surfaceReader.snapshot(ownedBy: session.processIDs)
        for identity in snapshot.destroyedByWindowServer {
            logicalClosureEvidence[identity] = .destroyed
            pendingDestruction.insert(identity)
        }
        return snapshot
    }

    /// Folds one reading of the assigned instance's surfaces through both nuclei.
    ///
    /// It is called where the seat already takes readings: after an adoption, at
    /// a target transfer, and before an observation. Two folds that agree are
    /// what verify a surface, which is why the observation path folds again
    /// rather than trusting the fold the adoption made.
    ///
    /// It is also where every held window's staging is read back, for the same
    /// reason and from the same reading: `isStaged` written once at adoption
    /// describes the moment of the adoption, and Stage Manager stashes a window
    /// long after it without telling anybody.
    func foldCurrentReading(at now: UInt64 = DispatchTime.now().uptimeNanoseconds) {

        guard assignmentKit.lifecycle.isAssigned else { return }
        let snapshot = readSurfaces()
        var reading  = snapshot.inventory
        let claims   = snapshot.claims

        if reading.completeness.isQualified {
            for claim in claims.visibilities {
                switch claim.state {
                    case .withdrawnEstablished:
                        logicalClosureEvidence[claim.surface] = .withdrawn
                    case .visibleInteractive:
                        logicalClosureEvidence[claim.surface] = nil
                        reconciledLogicalClosures.remove(claim.surface)
                    case .hiddenEstablished, .minimisedEstablished, .uncertain:
                        break
                }
            }
            for identity in snapshot.withdrawnByApplication {
                logicalClosureEvidence[identity] = .withdrawn
            }
            // A retained off-screen proxy is still a WindowServer row after
            // its logical panel closes. Re-ingesting that row would invent a
            // new held member and an obligation on every subsequent pass.
            let stillWithdrawn = Set(claims.visibilities.compactMap { claim in
                claim.state == .withdrawnEstablished ? claim.surface : nil
            }).intersection(reconciledLogicalClosures)
            reading = SurfaceInventoryReading(
                rows: reading.rows.filter { row in
                    row.surface.reference.identity.map { !stillWithdrawn.contains($0) } ?? true
                },
                completeness: reading.completeness
            )
        }

        // Before the fold, so the destroyed member is gone from membership for
        // this pass instead of spending another pass of its containment budget.
        // Proof another reader took is drained here too, because this is the
        // only reading that ends a containment wait.
        for identity in pendingDestruction.sorted(by: { $0.windowNumber < $1.windowNumber }) {
            AgentSeat.observationLog.notice("""
                the window server confirmed window \(identity.windowNumber, privacy: .public) \
                was destroyed: ending its containment wait
                """)
            noteSurfaceGone(identity.windowNumber, evidence: .windowServerConfirmedDestruction)
            _ = dropDestroyedRecord(identity.windowNumber)
        }
        pendingDestruction.removeAll()

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
        for claim in claims.recency {
            // A front-order change observed while placing this identity is not an application choice.
            guard claim.surface != adoptingPlacementIdentity else { continue }
            selectionKit.noteRecency(claim)
        }

        // A window the application stopped scoping is gone even though the
        // window server still shows a surface for it. Without this the member
        // stays absent-uncertain forever, containment never verifies again, and
        // the seat is suspended on a window nobody can bring back.
        for identity in snapshot.withdrawnByApplication {
            AgentSeat.observationLog.notice("""
                the application withdrew window \(identity.windowNumber, privacy: .public),                 which the window server still shows: confirming its closure
                """)
            noteSurfaceGone(identity.windowNumber, evidence: .applicationWithdrewTheWindow)
            guard !keepsWithdrawnTarget(identity) else { continue }
            _ = dropDestroyedRecord(identity.windowNumber)
        }

        // Stage Manager stashes a window whenever another window of the same
        // application is raised, and it tells nobody: so staging is read here.
        session.refreshStaging { sensing.windowGeometry(of: $0)?.frame.size }
        synchronizeSessionTargetWithSelection()
    }

    /// Reads the assigned application's own scoped surface evidence for one
    /// logical identity without changing selection or declaring a closure.
    ///
    /// The reader's retained result is essential here. A hidden parent that a
    /// child still attests is not withdrawn, and an unavailable or incomplete
    /// pass cannot establish an absence. Only an explicit application
    /// withdrawal or the reader's named WindowServer destruction proof returns
    /// a closed state.
    public func logicalSurfacePresence(of identity: WindowIdentity) -> LogicalSurfacePresence {
        guard let assignment = assignmentKit.lifecycle.current,
              assignment.instance == identity.process,
              session.processIdentities.contains(identity.process)
        else { return .unreadable }

        let snapshot = readSurfaces()
        guard snapshot.inventory.completeness.isQualified else { return .unreadable }

        if let visibility = snapshot.claims.visibilities.first(where: { $0.surface == identity }) {
            switch visibility.state {
                case .withdrawnEstablished:
                    logicalClosureEvidence[identity] = .withdrawn
                    return .withdrawn
                case .visibleInteractive:
                    logicalClosureEvidence[identity] = nil
                    reconciledLogicalClosures.remove(identity)
                    return .present
                case .hiddenEstablished, .minimisedEstablished:
                    return .present
                case .uncertain:
                    return .unreadable
            }
        }

        switch snapshot.retained[identity] {
            case .destroyed?:
                return .destroyed
            case .withdrawn?:
                logicalClosureEvidence[identity] = .withdrawn
                return .withdrawn
            case .unrelated?:       return .replaced
            case .obscuredByChild?: return .present
            case .temporarilyUnreadable?: return .unreadable
            case nil: break
        }

        if snapshot.inventory.rows.contains(where: { $0.surface.reference.identity == identity }) {
            return .present
        }
        if snapshot.inventory.rows.contains(where: {
            $0.surface.reference.windowNumber == identity.windowNumber
                && $0.surface.reference.identity != identity
        }) {
            return .replaced
        }
        if let closure = logicalClosureEvidence[identity] { return closure }
        return .unreadable
    }

    /// Reconciles a logical panel only on positive scoped closure evidence.
    /// This releases the held record before the next focus/release pass; an
    /// unreadable or merely hidden proxy remains untouched.
    @discardableResult
    public func reconcileLogicalClosure(of identity: WindowIdentity) -> LogicalSurfacePresence {
        let presence = logicalSurfacePresence(of: identity)
        let evidence: ClosureEvidence
        switch presence {
            case .withdrawn: evidence = .applicationWithdrewTheWindow
            case .destroyed: evidence = .windowServerConfirmedDestruction
            case .present, .replaced, .unreadable: return presence
        }
        reconciledLogicalClosures.insert(identity)
        noteSurfaceGone(identity.windowNumber, evidence: evidence)
        _ = dropDestroyedRecord(identity.windowNumber)
        return presence
    }

    /// Keeps the seat's operating-window record aligned with a qualified
    /// application-local selection transition. This changes no placement: the
    /// selected window is already a held record, and a withdrawn modal must not
    /// be staged merely to stop targeting it.
    ///
    /// Only a selection generation this seat has not aligned yet moves the
    /// record. A disagreement the seat itself just created is the other
    /// direction of the same relation: the seat moves its target first and asks
    /// the nucleus after, and a refused explicit selection leaves the previous
    /// surface selected at the generation already aligned. Following it back
    /// would undo the consumer's own target change and strand the selection the
    /// gate reports on. A transition that is still waiting for its window to be
    /// adopted keeps its generation unaligned and is applied at a later fold.
    ///
    /// It yields `targetChanged` with reason `detected`, which is what this move
    /// is to a consumer: the seat followed the application, and nothing on the
    /// consumer's side asked for it or was expecting it. It is the only event
    /// for this move, and the adoption that moves a target itself is the only
    /// event for that one. Without it the preview and the consumer kept
    /// composing Commands for a window the seat had already left.
    ///
    /// ## And it never carries a detected window onto the target
    ///
    /// A detected adoption does not take the target any more, and this path
    /// would otherwise have taken it for the same window a moment later by
    /// another route: a qualified recency drops the nucleus's standing choice,
    /// and a surface that raised itself is then the most recent candidate.
    /// Measured as a row of `AppWindowFollowTests` before this gate existed.
    ///
    /// So the seat follows the nucleus only onto a window it has operated
    /// before, which is the application moving between the consumer's own
    /// windows, or when the window it is operating stopped being one the
    /// nucleus would select at all, which is the target being gone. A window
    /// the seat adopted by itself and never operated is neither, and the
    /// consumer reaches it with `switchTarget(to:)`.
    private func synchronizeSessionTargetWithSelection() {

        guard let selected = selectionKit.selected else { return }
        guard session.currentTargetNumber != selected.surface.windowNumber else {
            alignedSelectionGeneration = selectionKit.selectionGeneration
            return
        }
        // A real document choice may name a held window never previously targeted.
        // Merely making an auxiliary surface eligible does not grant it that path.
        let applicationDocument = selected.reason == .qualifiedRecency
            && selectionKit.core.facts[selected.surface]?.role == .document
        guard session.targetHistory.contains(selected.surface.windowNumber)
                || applicationDocument
                || operatingTargetStoppedQualifying()
        else { return }

        let generation = selectionKit.selectionGeneration
        guard generation != alignedSelectionGeneration,
              let record = session[selected.surface.windowNumber],
              record.window.reference.identity == selected.surface
        else { return }

        let displaced = session.currentTargetNumber
        alignedSelectionGeneration = generation
        session.makeCurrent(selected.surface.windowNumber)
        if record.isStaged { stagedWindowNumber = selected.surface.windowNumber }
        // The window this follows may have taken the guard with it: Resolve's
        // Project Manager, withdrawn when a project opens, left nothing before
        // it in the target history.
        seatGuard = SeatGuard(
            target       : record.window.reference,
            displayID    : seatGuard?.displayID ?? displayID,
            displayBounds: seatGuard?.displayBounds ?? sensing.virtualDisplayBounds
        )
        observationIssuer.invalidate(.targetChanged)
        outstandingGeometry = nil
        eventChannel.yield(
            .targetChanged(
                from  : displaced,
                to    : record.window.reference,
                reason: .detected
            )
        )
        // A target kept through its withdrawal is let go once another window took over.
        if let displaced, let kept = session[displaced]?.window.reference.identity,
           logicalClosureEvidence[kept] == .withdrawn,
           assignmentKit.inventory.surfaces[displaced]?.identity != kept {
            _ = dropDestroyedRecord(displaced)
        }
        publishCoherentState()
    }

    /// Whether the window the seat is operating stopped being one the nucleus
    /// would select: no target at all, a target it no longer holds a record
    /// for, or a surface that is no longer a candidate because it was hidden,
    /// minimised or withdrawn.
    ///
    /// It is what lets the seat leave a target that is gone for a window it has
    /// never operated. A target that is still a candidate is the consumer's to
    /// move and nobody else's.
    ///
    /// ## A modal block is not a target that is gone
    ///
    /// A sheet the driven application puts up over the target removes the target
    /// from the candidates, and this used to read that as the target being gone
    /// and hand the session to the sheet. Measured on 18/09/2026 with Slack's
    /// attach panel: window 45288 was the target, sheet 46128 appeared, the
    /// session moved onto the sheet and every Command already decided on 45288
    /// was refused mid action as "the observation is no longer current". The
    /// window the consumer was working in had not gone anywhere, and it comes
    /// back the moment the sheet closes. So a target that is only modally
    /// blocked stays the target, and the sheet is reached through its host's
    /// picture instead, which is what `observationPicture(for:)` does.
    private func operatingTargetStoppedQualifying() -> Bool {

        guard let number   = session.currentTargetNumber,
              let identity = session[number]?.window.reference.identity
        else { return true }
        guard !selectionKit.status().candidates.contains(identity) else { return false }
        return !selectionKit.isModallyBlocked(identity)
    }

    /// Which surface one observation of `selected` takes its pixels and its
    /// geometry from, and the role that says so.
    ///
    /// A window-scoped modal is drawn inside the window it blocks and has no
    /// surface of its own to capture, so the picture is the host's, whole and
    /// unscaled, and the reference carries the sheet as the operating surface.
    /// See `ObservedSurfaceRole.hostedSheet` for the reading this rests on.
    ///
    /// A modal whose host the seat holds no record for keeps its own picture:
    /// there is nothing to aim at instead, and substituting a window the seat
    /// cannot address would be worse than the black band.
    ///
    /// ## The stack, not the step above
    ///
    /// A dialog opened from inside a panel has a sheet for a host, and a sheet
    /// has no surface of its own to capture either, so one step up would aim
    /// the capture at the next proxy and deliver exactly the band this is here
    /// to avoid. The walk climbs to the outermost window the seat holds a
    /// record for. It terminates on the attested relations alone, which the
    /// selection nucleus already refuses to let close a loop, and the visited
    /// set bounds it whatever those relations say.
    func observationPicture(
        for selected: WindowIdentity
    ) -> (surface: WindowIdentity, role: ObservedSurfaceRole) {

        var visited: Set<WindowIdentity> = [selected]
        var current = selected
        var outermost: WindowIdentity?

        while let host = selectionKit.attachedHost(of: current),
              visited.insert(host).inserted,
              session[host.windowNumber]?.window.reference.identity == host {
            outermost = host
            current   = host
        }
        guard let outermost else { return (selected, .ordinaryTarget) }
        return (outermost, .hostedSheet(sheet: selected))
    }

    /// The window `surface` is drawn inside while the seat cannot aim a capture
    /// at that window, nil when the surface has pixels of its own.
    ///
    /// It is asked of the surface the picture settled on, which is what makes
    /// one question cover the two ways the climb ends short. A modal whose host
    /// the seat never took stops the climb at the first step; a dialog nested in
    /// a panel whose own host the seat never took stops it at the panel, and the
    /// panel is a proxy exactly as the dialog is. Either way the surface still
    /// names a host, and what ScreenCaptureKit returns for it is the host's
    /// picture in that surface's rectangle.
    ///
    /// The named host comes from the modal scope the application declared, not
    /// from the blocks in force among the members: a host that is not a member
    /// is the case this exists for, and `attachedHost(of:)` is silent about it
    /// by design.
    func unresolvedModalHost(of surface: WindowIdentity) -> WindowIdentity? {
        selectionKit.namedModalHost(of: surface)
    }

    /// Where one Command decided on a hosted sheet observation is addressed,
    /// together with the surface record the seat holds for it.
    ///
    /// `nil` is "there is nothing to redirect", which is an ordinary target. A
    /// thrown `InputEndpointRefusal` is a modal surface whose recipient could
    /// not be attested, and it is never answered by posting to the host
    /// instead.
    ///
    /// ## The two contracts are resolved from different evidence
    ///
    /// A mouse gesture is decided by its point, and a key is not: it goes to
    /// the key window and its first responder, so its context is the focused
    /// node of the topmost modal surface and never the last place the pointer
    /// went. The keyboard branch therefore asks the discovery for no point at
    /// all, and records the focused node's own window on the endpoint so a
    /// focus that moves afterwards retires it.
    ///
    /// ## One resolution for the whole gesture
    ///
    /// The point that resolves it is the Command's **first**, which is the
    /// point of the down. A drag is one Command, its press, its steps and its
    /// release are rebased onto that one endpoint together, and there is no
    /// second resolution anywhere that could hand the release to another
    /// process while the button is down.
    ///
    /// ## The geometry rule
    ///
    /// The picture and its `FrameGeometryObservation` are the host's, so a
    /// consumer's `InputLocation(pixelPoint:observedIn:)` already yields a true
    /// screen point and a window point measured from the host's origin: a point
    /// anywhere in that picture is admissible. The screen point is what is
    /// kept; only the window point is measured again, from the endpoint's own
    /// origin, which is what the routed process reads.
    ///
    /// The surface rectangle is read here and now, not taken from the record
    /// the adoption wrote: a record kept from the adoption describes the frame
    /// the sheet was at. The endpoint's own geometry is read by the discovery
    /// between two agreeing identity readings, and it is that reading, not the
    /// record, that becomes the reference handed to the driver. The driver
    /// reads the same window again before its first post and compares with
    /// `WindowCoordinateValidator.requireUnchanged`, so a surface that moved in
    /// between refuses rather than being clicked where it used to be.
    ///
    /// ## A point outside the modal surface is refused
    ///
    /// It used to fall back to the host. The host is the window the modal is
    /// blocking: delivering it the events aimed past its own dialog is the one
    /// thing a modal relation means must not happen.
    func inputEndpoint(
        for command: InputCommand,
        observation: SeatObservationReference
    ) throws -> (endpoint: ResolvedInputEndpoint, surface: AdoptedWindow)? {

        // Capture role says where the pixels came from. It is deliberately not
        // the authority for input: an application-modal panel can have its own
        // pixels while still being a logical modal surface with remote content.
        // The observation's surface is the only fallback logical surface. A
        // failed speculative descent over a normal window remains its existing
        // route, while a modal relation continues to fail closed.
        let modalSurface = attestedModalSurface(for: observation)
        let hasAttestedModalRelation = modalSurface != nil
        let sheet = modalSurface ?? observation.surface

        let host = selectionKit.attachedHost(of: sheet)
            ?? selectionKit.namedModalHost(of: sheet)
            ?? sheet
        guard let record = session[sheet.windowNumber],
              record.window.reference.identity == sheet,
              let instance = assignmentKit.lifecycle.current?.instance
        else { throw InputEndpointRefusal.subtreeUnreadable(surface: sheet) }

        guard let geometry = sensing.windowGeometryObservation(of: record.window.reference),
              geometry.window.identity == sheet
        else { throw InputEndpointRefusal.geometryUnavailable(windowNumber: sheet.windowNumber) }

        let chain = DialogEndpointResolver<AXUIElement>.SurfaceChain(
            host        : host,
            surface     : sheet,
            surfaceFrame: geometry.window.frame
        )
        var outcome: Result<ResolvedInputEndpoint, InputEndpointRefusal>
        if let point = command.firstMouseScreenPoint {
            guard geometry.window.frame.contains(point) else {
                throw InputEndpointRefusal.pointOutsideSurface
            }
            outcome = endpoints.pointer(
                instance.processID,
                point,
                chain,
                observation.selectionGeneration
            )
        } else {
            outcome = endpoints.keyboardContext(
                instance.processID,
                chain,
                observation.selectionGeneration
            )
            if hasAttestedModalRelation,
               let remote = remoteContentKeyboardContext(
                   after     : outcome,
                   processID : instance.processID,
                   chain     : chain,
                   generation: observation.selectionGeneration
               ) {
                let why = remote.evidence == .focusedSurfaceDescendant
                    ? "has a focused descendant in its remote content window"
                    : "answers no readable focus and names one remote content window"
                AgentSeat.observationLog.notice("""
                    modal window \(sheet.windowNumber, privacy: .public) \(why, privacy: .public), \
                    \(remote.identity.windowNumber, privacy: .public), so its keys go there: the \
                    discovery had answered \(String(describing: outcome), privacy: .public)
                    """)
                outcome = .success(remote)
            }
            if case .failure(.subtreeUnreadable) = outcome {
                outcome = hasAttestedModalRelation
                    ? endpoints.focusedDescendantKeyboardContext(
                        instance.processID, chain, observation.selectionGeneration
                    )
                    : endpoints.ordinaryKeyboardContext(
                        instance.processID, chain, observation.selectionGeneration
                    )
            }
        }
        // Containment alone can admit a blocked document's Stage Manager
        // thumbnail. Modal eligibility remains authoritative for its recipient.
        if case .success(let endpoint) = outcome,
           endpoint.identity != sheet,
           selectionKit.modals(blocking: endpoint.identity).contains(sheet) {
            outcome = .failure(.recipientModallyBlocked(windowNumber: endpoint.identity.windowNumber))
        }
        if command.firstMouseScreenPoint == nil,
           !hasAttestedModalRelation,
           record.platform is UXPPlatform,
           canPrimeOwnUXPDocument(sheet),
           case .failure(.subtreeUnreadable) = outcome {
            outcome = endpoints.mainWindowUnderFocusProxyKeyboardContext(
                instance.processID, chain, observation.selectionGeneration
            )
        }
        let mayReadOwnWindowlessContent: Bool
        switch outcome {
            case .failure(.subtreeUnreadable):
                mayReadOwnWindowlessContent = true
            case .success(let endpoint):
                // A windowless focused control can have an auxiliary themed widget
                // elsewhere in its subtree. Prefer its own parentage if proved.
                mayReadOwnWindowlessContent = command.firstMouseScreenPoint == nil
                    && endpoint.kind == .keyboardContext
                    && endpoint.relation == .remoteContent
                    && endpoint.evidence == .remoteContentOfSurface
                    && endpoint.logicalSurface == sheet
            default:
                mayReadOwnWindowlessContent = false
        }
        if !hasAttestedModalRelation,
           mayReadOwnWindowlessContent,
           case .success(let content) = endpoints.windowlessContent(
               instance.processID,
               command.firstMouseScreenPoint,
               chain,
               observation.selectionGeneration
           ) {
            AgentSeat.observationLog.notice("""
                the \(content.kind == .pointer ? "node under the point" : "focused control", privacy: .public) \
                on window \(sheet.windowNumber, privacy: .public) names no Window ID and is drawn inside \
                it, so its events go to it: the discovery had answered \
                \(String(describing: outcome), privacy: .public)
                """)
            outcome = .success(content)
        }
        switch outcome {
            case .success(let endpoint):
                return (endpoint, record.window)

            case .failure(.noNodeAtPoint) where !hasAttestedModalRelation:
                // A normal application window may have no auxiliary endpoint
                // under a point; its already-held surface remains the route.
                return nil

            case .failure(let refusal):
                let kind: InputEndpointKind = command.firstMouseScreenPoint == nil ? .keyboardContext : .pointer
                if hasAttestedModalRelation {
                    switch endpoints.leafSurface(instance.processID, kind, chain, observation.selectionGeneration) {
                        case .success(let endpoint):
                            AgentSeat.observationLog.notice("""
                                modal window \(sheet.windowNumber, privacy: .public) is a single \
                                accessibility leaf, so its events go to it: the discovery had refused \
                                with \(String(describing: refusal), privacy: .public)
                                """)
                            return (endpoint, record.window)
                        case .failure(let leaf):
                            AgentSeat.observationLog.notice("""
                                modal window \(sheet.windowNumber, privacy: .public) is no single \
                                accessibility leaf either: \(String(describing: leaf), privacy: .public)
                                """)
                    }
                }
                let mayPrimeModal: Bool
                switch refusal {
                    case .notContainedInSurface(let number), .recipientModallyBlocked(let number):
                        let blocked = session[number]?.window.reference.identity
                        mayPrimeModal = blocked?.process == sheet.process && blocked != sheet
                    case .subtreeUnreadable(let surface) where surface == sheet:
                        mayPrimeModal = endpoints.focusedWindowNumber(instance.processID) == nil
                    default:
                        mayPrimeModal = false
                }
                if kind == .keyboardContext,
                   record.platform is UXPPlatform,
                   canPrimeOwnUXPDialog(sheet),
                   mayPrimeModal,
                   case .success(let modal) = endpoints.modalSurfaceKeyboardContext(
                       instance.processID, chain, observation.selectionGeneration
                   ) {
                    AgentSeat.observationLog.notice("""
                        UXP dialog window \(sheet.windowNumber, privacy: .public) has a complete \
                        own-window subtree despite absent or blocked AX focus; \
                        make only the modal key for input
                        """)
                    return (modal, record.window)
                }
                AgentSeat.observationLog.notice("""
                    the input endpoint discovery refused: \
                    \(String(describing: refusal), privacy: .public)
                    """)
                throw refusal
        }
    }

    /// How long `platform` waits on purpose before the first event of `command`.
    static func preparationWait(of platform: any InputPlatform, for command: InputCommand) -> Duration {
        let settle = platform.preparation(for: command) == .internalAppKitState
            ? platform.preparationSettle(for: command)
            : .zero
        return settle + (platform.keyWindowPriming(for: command)?.settle ?? .zero)
    }

    /// The one modal-relation predicate shared by endpoint discovery and focus
    /// recovery. Capture may observe an ordinary surface, so it cannot decide
    /// whether a successful speculative endpoint is a dialog closure.
    func attestedModalSurface(for observation: SeatObservationReference) -> WindowIdentity? {
        if let sheet = observation.role.attachedSheet { return sheet }
        let surface = observation.surface
        guard selectionKit.namedModalHost(of: surface) != nil
                || selectionKit.isApplicationModal(surface)
        else { return nil }
        return surface
    }

    /// The remote content a modal surface's keys go to instead of what the
    /// keyboard discovery answered, `nil` to keep that answer.
    ///
    /// After a refusal for an unreadable subtree it asks
    /// `remoteContentKeyboardContext`, which re-reads the focus to tell an
    /// unreadable one from the other causes. After an answer that is the surface
    /// itself, which is what a focus on its own window node resolves to, it asks
    /// `focusedContentKeyboardContext`: a fresh panel keeps the surface, where
    /// Escape was measured to work, and a panel whose field was clicked sends
    /// the keys to that field's window. Only a window of the qualified panel
    /// service is taken, the one case the remote keyboard recipe and its host
    /// priming were measured on; any other keeps the discovery's answer.
    /// Resolution and boundary both come through here, so they cannot disagree.
    private func remoteContentKeyboardContext(
        after reading: Result<ResolvedInputEndpoint, InputEndpointRefusal>,
        processID    : Int32,
        chain        : DialogEndpointResolver<AXUIElement>.SurfaceChain,
        generation   : UInt64
    ) -> ResolvedInputEndpoint? {
        let route: Result<ResolvedInputEndpoint, InputEndpointRefusal>
        switch reading {
            case .failure(.subtreeUnreadable):
                route = endpoints.remoteContentKeyboardContext(processID, chain, generation)
            case .success(let found) where found.relation == .logicalSurface:
                route = endpoints.focusedContentKeyboardContext(processID, chain, generation)
            case .success, .failure:
                return nil
        }
        guard case .success(let remote) = route,
              remote.identity.process != remote.logicalSurface.process,
              endpoints.qualifiedAppKitPanelService(remote.identity)
        else { return nil }
        return remote
    }

    /// Qualifies the key-window recipe for an application modal, or for an
    /// independently selected dialog whose AX modality is false. A document,
    /// a hosted sheet and an unselected sibling cannot borrow this proof.
    private func canPrimeOwnUXPDialog(_ surface: WindowIdentity) -> Bool {
        guard selectionKit.selected?.surface == surface else { return false }
        if selectionKit.isApplicationModal(surface) { return true }
        return selectionKit.core.facts[surface]?.role == .dialog
            && selectionKit.attachedHost(of: surface) == nil
            && selectionKit.namedModalHost(of: surface) == nil
    }

    /// Restricts the inert-focus-proxy recipe to the selected standalone,
    /// unblocked document. A modal relation cannot borrow that proof.
    private func canPrimeOwnUXPDocument(_ surface: WindowIdentity) -> Bool {
        selectionKit.selected?.surface == surface
            && selectionKit.core.facts[surface]?.role == .document
            && selectionKit.modals(blocking: surface).isEmpty
            && !selectionKit.isApplicationModal(surface)
            && selectionKit.attachedHost(of: surface) == nil
            && selectionKit.namedModalHost(of: surface) == nil
    }

    /// Why a resolved endpoint may no longer be used, read against the world as
    /// it is at the boundary before the driver builds.
    ///
    /// The identity is asked of the window server directly and not of the
    /// sensing reader, because the sensing reader answers from the public window
    /// list and the recipient can be a window that list does not enumerate.
    ///
    /// A keyboard context is asked one thing more: where the internal focus is
    /// now. Its own window can be alive, unchanged and still the wrong place to
    /// type, which is what a focus that moved between the resolution and the
    /// boundary means.
    ///
    /// `grace` is time the recipe itself waited between the resolution and this
    /// reading, the preparation's settle and the host's priming: measured on
    /// 30/09/2026, a UXP key resolved at .988 was refused as expired at .548,
    /// 60 ms past its 500 ms, with nothing in the world changed. Every other
    /// reading is still taken now.

    func endpointInvalidation(
        of endpoint    : ResolvedInputEndpoint,
        allowing grace : Duration = .zero
    ) -> InputEndpointInvalidation? {
        if endpoint.identity != endpoint.logicalSurface,
           selectionKit.modals(blocking: endpoint.identity).contains(endpoint.logicalSurface) {
            return .relationNoLongerValid
        }
        let focused: Int?
        if endpoint.evidence == .focusedSurfaceDescendant
            || endpoint.kind == .keyboardContext && endpoint.evidence == .remoteContentOfSurface {
            guard let instance = assignmentKit.lifecycle.current?.instance,
                  let record = session[endpoint.logicalSurface.windowNumber],
                  record.window.reference.identity == endpoint.logicalSurface,
                  let geometry = sensing.windowGeometryObservation(of: record.window.reference),
                  geometry.window.identity == endpoint.logicalSurface,
                  endpoint.evidence == .remoteContentOfSurface
                    || selectionKit.namedModalHost(of: endpoint.logicalSurface) != nil
                    || selectionKit.isApplicationModal(endpoint.logicalSurface)
            else { return .focusedNodeChanged }

            let generation = selectionKit.selected?.generation ?? .max
            let chain = DialogEndpointResolver<AXUIElement>.SurfaceChain(
                host: selectionKit.attachedHost(of: endpoint.logicalSurface)
                    ?? selectionKit.namedModalHost(of: endpoint.logicalSurface)
                    ?? endpoint.logicalSurface,
                surface: endpoint.logicalSurface,
                surfaceFrame: geometry.window.frame
            )
            // A newly exposed direct focused control can replace the subtree
            // proof, but it must still name the same attested recipient.
            var reading = endpoints.keyboardContext(instance.processID, chain, generation)
            // The resolution's own routes for a modal's unreadable or window-node focus.
            if selectionKit.namedModalHost(of: endpoint.logicalSurface) != nil
                   || selectionKit.isApplicationModal(endpoint.logicalSurface),
               let remote = remoteContentKeyboardContext(
                   after     : reading,
                   processID : instance.processID,
                   chain     : chain,
                   generation: generation
               ) {
                reading = .success(remote)
            }
            if case .failure(.subtreeUnreadable) = reading {
                reading = endpoints.focusedDescendantKeyboardContext(
                    instance.processID, chain, generation
                )
            }
            guard case .success(let current) = reading,
                  current.kind == .keyboardContext,
                  current.logicalSurface == endpoint.logicalSurface,
                  current.relation == endpoint.relation,
                  current.identity == endpoint.identity,
                  current.geometry.window.frame == endpoint.geometry.window.frame,
                  current.geometry.scaleFactor == endpoint.geometry.scaleFactor,
                  current.selectionGeneration == endpoint.selectionGeneration,
                  current.focusedNodeWindowNumber == endpoint.identity.windowNumber
            else { return .focusedNodeChanged }
            focused = current.focusedNodeWindowNumber
        } else if endpoint.evidence == .unfocusedModalSurface {
            guard let instance = assignmentKit.lifecycle.current?.instance,
                  let record = session[endpoint.logicalSurface.windowNumber],
                  record.platform is UXPPlatform,
                  canPrimeOwnUXPDialog(endpoint.logicalSurface),
                  record.window.reference.identity == endpoint.logicalSurface,
                  let geometry = sensing.windowGeometryObservation(of: record.window.reference),
                  geometry.window.identity == endpoint.logicalSurface,
                  case .success(let current) = endpoints.modalSurfaceKeyboardContext(
                      instance.processID,
                      DialogEndpointResolver<AXUIElement>.SurfaceChain(
                          host: endpoint.logicalSurface, surface: endpoint.logicalSurface,
                          surfaceFrame: geometry.window.frame
                      ),
                      selectionKit.selected?.generation ?? .max
                  ),
                  current.evidence == .unfocusedModalSurface,
                  current.kind == .keyboardContext,
                  current.relation == .logicalSurface,
                  current.focusedNodeWindowNumber == nil,
                  current.identity == endpoint.identity,
                  current.logicalSurface == endpoint.logicalSurface,
                  current.geometry.window.frame == endpoint.geometry.window.frame,
                  current.geometry.scaleFactor == endpoint.geometry.scaleFactor,
                  current.selectionGeneration == endpoint.selectionGeneration
            else { return .relationNoLongerValid }
            focused = nil
        } else if endpoint.evidence == .mainWindowUnderFocusProxy {
            guard let instance = assignmentKit.lifecycle.current?.instance,
                  let record = session[endpoint.logicalSurface.windowNumber],
                  record.platform is UXPPlatform,
                  canPrimeOwnUXPDocument(endpoint.logicalSurface),
                  record.window.reference.identity == endpoint.logicalSurface,
                  let geometry = sensing.windowGeometryObservation(of: record.window.reference),
                  geometry.window.identity == endpoint.logicalSurface
            else { return .relationNoLongerValid }
            let chain = DialogEndpointResolver<AXUIElement>.SurfaceChain(
                host: endpoint.logicalSurface, surface: endpoint.logicalSurface,
                surfaceFrame: geometry.window.frame
            )
            let generation = selectionKit.selected?.generation ?? .max
            var reading = endpoints.keyboardContext(instance.processID, chain, generation)
            if case .failure = reading {
                reading = endpoints.ordinaryKeyboardContext(instance.processID, chain, generation)
            }
            if case .failure = reading {
                reading = endpoints.mainWindowUnderFocusProxyKeyboardContext(instance.processID, chain, generation)
            }
            // Exact key-window priming can replace the proxy with direct focus.
            // Both proofs must still name this document and this observation.
            guard case .success(let current) = reading,
                  current.kind == .keyboardContext,
                  current.relation == .logicalSurface,
                  current.identity == endpoint.identity,
                  current.logicalSurface == endpoint.logicalSurface,
                  current.geometry.window.frame == endpoint.geometry.window.frame,
                  current.geometry.scaleFactor == endpoint.geometry.scaleFactor,
                  current.selectionGeneration == endpoint.selectionGeneration,
                  (current.evidence == .mainWindowUnderFocusProxy && current.focusedNodeWindowNumber == nil)
                    || ((current.evidence == .attestedSurfaceItself || current.evidence == .focusedWindowWithoutFocusedControl)
                        && current.focusedNodeWindowNumber == endpoint.identity.windowNumber)
            else { return .relationNoLongerValid }
            focused = endpoint.focusedNodeWindowNumber
        } else if endpoint.evidence == .focusedWindowWithoutFocusedControl {
            guard let instance = assignmentKit.lifecycle.current?.instance else {
                return .focusedNodeChanged
            }
            let generation = selectionKit.selected?.generation ?? .max
            let chain = DialogEndpointResolver<AXUIElement>.SurfaceChain(
                host: endpoint.logicalSurface,
                surface: endpoint.logicalSurface,
                surfaceFrame: endpoint.geometry.window.frame
            )

            switch endpoints.keyboardContext(instance.processID, chain, generation) {
            case .success(let current):
                // A control may materialize while the command gate is settling.
                // It replaces the absence proof only when it resolves back to
                // this exact ordinary window. A remote descendant, a new
                // geometry, or a different selection still retires the route.
                guard current.kind == .keyboardContext,
                      current.evidence == .attestedSurfaceItself,
                      current.relation == .logicalSurface,
                      current.logicalSurface == endpoint.logicalSurface,
                      current.identity == endpoint.identity,
                      current.geometry.window.frame == endpoint.geometry.window.frame,
                      current.geometry.scaleFactor == endpoint.geometry.scaleFactor,
                      current.selectionGeneration == endpoint.selectionGeneration,
                      current.focusedNodeWindowNumber == endpoint.identity.windowNumber
                else { return .focusedNodeChanged }
                focused = current.focusedNodeWindowNumber

            case .failure:
                guard case .success(let current) = endpoints.ordinaryKeyboardContext(
                    instance.processID, chain, generation
                ),
                current.kind == .keyboardContext,
                current.evidence == .focusedWindowWithoutFocusedControl,
                current.relation == .logicalSurface,
                current.logicalSurface == endpoint.logicalSurface,
                current.identity == endpoint.identity,
                current.geometry.window.frame == endpoint.geometry.window.frame,
                current.geometry.scaleFactor == endpoint.geometry.scaleFactor,
                current.selectionGeneration == endpoint.selectionGeneration,
                current.focusedNodeWindowNumber == endpoint.identity.windowNumber
                else { return .focusedNodeChanged }
                focused = current.focusedNodeWindowNumber
            }
        } else if endpoint.kind == .keyboardContext, endpoint.evidence == .windowlessContentOfSurface {
            // The focused control names no window, so the plain focus reading
            // would answer nil: the same proof is taken again instead.
            guard let instance = assignmentKit.lifecycle.current?.instance,
                  case .success(let current) = endpoints.windowlessContent(
                      instance.processID,
                      nil,
                      DialogEndpointResolver<AXUIElement>.SurfaceChain(
                          host        : endpoint.logicalSurface,
                          surface     : endpoint.logicalSurface,
                          surfaceFrame: endpoint.geometry.window.frame
                      ),
                      selectionKit.selected?.generation ?? .max
                  ),
                  current.kind == .keyboardContext,
                  current.evidence == .windowlessContentOfSurface,
                  current.identity == endpoint.identity,
                  current.geometry.window.frame == endpoint.geometry.window.frame,
                  current.geometry.scaleFactor == endpoint.geometry.scaleFactor,
                  current.selectionGeneration == endpoint.selectionGeneration,
                  current.focusedNodeWindowNumber == endpoint.identity.windowNumber
            else { return .focusedNodeChanged }
            focused = current.focusedNodeWindowNumber
        } else {
            focused = endpoint.kind == .keyboardContext
                ? assignmentKit.lifecycle.current
                    .flatMap { endpoints.focusedWindowNumber($0.instance.processID) }
                : nil
        }
        let graceNanoseconds = UInt64(max(0, grace.components.seconds)) * 1_000_000_000
            + UInt64(max(0, grace.components.attoseconds / 1_000_000_000))
        return endpoint.invalidation(
            at                     : DispatchTime.now().uptimeNanoseconds &- graceNanoseconds,
            selectionGeneration    : selectionKit.selected?.generation ?? .max,
            logicalSurface         : selectionKit.selected?.surface,
            currentIdentity        : endpoints.identity(endpoint.identity.windowNumber),
            focusedNodeWindowNumber: focused
        )
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

    /// What the last qualified reading said a member window is, nil when nothing said.
    package func surfaceRole(ofWindow windowNumber: Int) -> SurfaceRole? {
        assignmentKit.inventory.surfaces[windowNumber].flatMap {
            selectionKit.core.facts[$0.identity]?.role
        }
    }

    /// Asks the selection nucleus for this surface explicitly, which is what a
    /// consumer's own target change is. A refusal is reported through the causes
    /// of the gate and never worked around here.
    func selectExplicitly(_ window: WindowReference) {
        guard let identity = window.identity else { return }
        foldCurrentReading()
        if case .failure(let refusal) = selectionKit.selectExplicitly(identity) {
            AgentSeat.observationLog.notice("""
                the explicit selection was refused: \(String(describing: refusal), privacy: .public)
                """)
        }
        // Both sides have just been reconciled by the seat itself, whichever way
        // the nucleus answered. Recording the generation here is what stops the
        // next fold from following this selection back onto the record the
        // consumer moved away from.
        alignedSelectionGeneration = selectionKit.selectionGeneration
    }

    /// Records that a surface the seat held is gone, on the seat's own proof of
    /// it: an explicit release or a destruction the recovery established. An
    /// absence from a reading is not this, and does not reach here.
    ///
    /// The closure is confirmed to the selection nucleus whichever surface it
    /// was: forgetting a closed window is not scoped to the observed one, and a
    /// surface nobody observes still has to stop being a candidate and stop
    /// spending its containment budget.
    ///
    /// The observation is the other half, and it is scoped to the surface the
    /// outstanding reference was issued for. The driven application publishes
    /// auxiliary surfaces of its own, held and released here like any window,
    /// and Finder's 66 by 20 point dialog is one: it is destroyed under a
    /// second, and invalidating on it ended the agent's observation of the
    /// window it was actually working in, reported as a target change that
    /// never happened. `outstandingGeometry` describes that same observation,
    /// so it is cleared on this condition and on no other.
    ///
    /// The comparison is by Window ID, which is what a closure carries, and not
    /// by the whole identity the reference holds. Identity is what settles
    /// whether a reference may act, and this settles whether one stops acting:
    /// an id the system handed out again can only end an observation that has
    /// to be taken again anyway, and never keep a dead one current.
    ///
    /// A hosted sheet is where the recipient and the operated surface are two
    /// different windows: the reference carries the host as its surface, so the
    /// nested dialog the agent was working in could close and leave its own
    /// observation current over a picture of the window underneath. Both are
    /// asked here, which is what makes the parent's context a new observation
    /// rather than the child's last one.
    func noteSurfaceGone(
        _ windowNumber: Int,
        evidence      : ClosureEvidence = .windowServerConfirmedDestruction
    ) {
        selectionKit.confirmClosure(
            of      : windowNumber,
            evidence: evidence
        )
        // A dialog the seat was closing stopped being listed, which an Electron
        // panel does before it completes: the short protection starts here.
        focusRecovery?.noteClosureSurfaceGone(windowNumber)
        let outstanding = observationIssuer.outstanding
        let operated = outstanding?.role.attachedSheet ?? outstanding?.recipient
        guard outstanding?.recipient.windowNumber == windowNumber
                || operated?.windowNumber == windowNumber
        else { return }
        observationIssuer.invalidate(.targetChanged)
        outstandingGeometry = nil
    }

    /// Lets go of an adopted window the window server proved destroyed, when it
    /// is not the one the seat is operating.
    ///
    /// The operating target has a second proof of its own, the recovery episode
    /// that spends its whole budget, and it keeps it. Every other record is a
    /// claim on a window that no longer exists, and the claim outlives the
    /// window: `windowsStillHeld` reads these records, so a destroyed dialog
    /// left among them refuses the handback of the entire assignment, and the
    /// focus recovery's snapshot of the adopted windows cannot come back valid
    /// while one of them cannot be read at all. That is the cycle this closes,
    /// from the side that has the proof.
    /// It is not private because the coordinated release of a whole assignment
    /// drops the operating target too: there is no recovery episode left to
    /// keep it for when every window is on its way out.
    @discardableResult
    func dropDestroyedRecord(_ windowNumber: Int) -> Bool {

        guard session[windowNumber] != nil else { return false }
        forgetRecord(windowNumber)
        if stagedWindowNumber == windowNumber { stagedWindowNumber = nil }
        releaseLedger[windowNumber] = .vanished
        eventChannel.yield(.windowReleased(windowNumber: windowNumber, outcome: .vanished))
        return true
    }

    /// Whether a window its application withdrew is the operating target with
    /// nothing held to hand the target to, and is therefore kept.
    ///
    /// The window server still shows it, and an application can stop listing
    /// its window for a moment. A DaVinci Resolve run reached `notAdopted` after
    /// an inspector value was edited, with its window still on screen, and this
    /// drop is the path in the code that leaves the seat with no target at all:
    /// nothing brought it back short of closing the session. Kept, the record
    /// stays the target with its platform and its return, the selection takes
    /// it back once it is listed again, and it is let go when another held
    /// window takes over.
    private func keepsWithdrawnTarget(_ identity: WindowIdentity) -> Bool {

        let number = identity.windowNumber
        guard session.currentTargetNumber == number,
              session[number]?.window.reference.identity == identity,
              session.predecessor(of: number) == nil
        else { return false }
        if let selected = selectionKit.selected?.surface,
           selected != identity,
           session[selected.windowNumber]?.window.reference.identity == selected {
            return false
        }
        logicalClosureEvidence[identity] = .withdrawn
        AgentSeat.observationLog.notice("""
            window \(number, privacy: .public) is the operating target and nothing held can \
            take over: keeping it until it is listed again or another window takes over
            """)
        return true
    }

    /// Ends the assignment and the observation half together. Input authority
    /// goes first, before any window moves, and the restitution the release left
    /// behind stays an explicit obligation rather than a success.
    func endAssignmentAndObservation(reason: ObservationInvalidation) {
        logicalClosureEvidence.removeAll()
        reconciledLogicalClosures.removeAll()
        pendingDestruction.removeAll()
        guard assignmentKit.lifecycle.isAssigned else {
            observationIssuer.invalidate(reason)
            outstandingGeometry = nil
            keyboardRecipients.removeAll()
            return
        }
        _ = assignmentKit.release()
        observationIssuer.invalidate(reason)
        outstandingGeometry = nil
        menuContext = nil
        // The recipients belong to the assignment that resolved them. The
        // stranded report above this has already read them.
        keyboardRecipients.removeAll()
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
        let deadlineNanoseconds = DispatchTime.now().uptimeNanoseconds
            &+ observationProfile.captureDeadlineNanoseconds
        foldCurrentReading()

        // A surface first seen by this request needs the second reading the
        // assignment nucleus requires before either selection or containment
        // may trust it. First let the owned window follower settle an outside
        // candidate through the adoption lifecycle; this also repairs a race in
        // which an earlier assignment fold reached its unqualified direct
        // effector before the follower. Then fold only once more inside the
        // capture request's existing deadline. A changing or incomplete
        // inventory still reaches the ordinary fail-closed gate.
        if selectionNeedsConfirmingReading() || selectedSurfaceNeedsOwnership() {
            await settleWindowFollowingForObservation(until: deadlineNanoseconds)
            // A window already open at the handover is in the follower's
            // baseline, so the seat takes that one in through the same path.
            if let refusal = await takeInRefusedPreexistingMembers(until: deadlineNanoseconds) {
                return .failure(refusal)
            }
            await Task.yield()
            guard !Task.isCancelled else {
                return .failure(.captureFailed(reason: String(describing: CancellationError())))
            }
            if let context = menuContext {
                return .failure(.menuInteractionActive(parent: context.parent))
            }
            guard DispatchTime.now().uptimeNanoseconds < deadlineNanoseconds else {
                return .failure(.captureDeadlineExpired(attemptsSpent: 0))
            }
            foldCurrentReading()
        }

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
        let selectedPicture = observationPicture(for: selected.surface)
        guard session[selectedPicture.surface.windowNumber]?.window.reference.identity
                == selectedPicture.surface
        else {
            // A selected window the seat could not take in is named where it is.
            let number = selectedPicture.surface.windowNumber
            guard assignmentKit.inventory.surfaces[number]?.presence == .outsideSeat else {
                return .failure(.suspended([.containmentNotVerified(blocks: ["selected surface is not owned"])]))
            }
            return .failure(.suspended([SeatSuspensionCause(
                .containmentNotVerified(blocks: [.surfaceOutsideSeat(windowNumber: number)])
            )]))
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
        // A cause about other windows of the application only travels with the
        // delivery: it does not hold back the picture of this one (ADR 0032).
        let observed  = observedWindowNumbers(of: selected.surface)
        let elsewhere = causes.filter { Self.isElsewhere($0, observing: observed) }
        causes.removeAll { elsewhere.contains($0) }
        guard causes.isEmpty else {
            return .failure(.suspended(causes.map(SeatSuspensionCause.init)))
        }

        guard observationSource.supports(.windowStill) else {
            return .failure(.capabilityUnqualified(.windowStill))
        }
        if let refusal = await stageStashedTarget(
            selected.surface,
            within: deadlineNanoseconds
        ) {
            return .failure(refusal)
        }
        // Source, represented frame and generation settle together here. A
        // surface still naming a host has no pixels of its own to publish.
        var chosen  = selected
        var picture = observationPicture(for: chosen.surface)
        if unresolvedModalHost(of: picture.surface) != nil {
            guard DispatchTime.now().uptimeNanoseconds < deadlineNanoseconds else {
                return .failure(.captureDeadlineExpired(attemptsSpent: 0))
            }
            foldCurrentReading()
            guard let settled = selectionKit.selected else { return .failure(.noSelectedTarget) }
            chosen  = settled
            picture = observationPicture(for: chosen.surface)
            if let host = unresolvedModalHost(of: picture.surface) {
                AgentSeat.observationLog.notice("""
                    window \(picture.surface.windowNumber, privacy: .public) is drawn inside \
                    window \(host.windowNumber, privacy: .public), which is not a window this \
                    seat can capture: refusing rather than publishing the modal's own picture
                    """)
                return .failure(.hostedSurfaceUnresolved(
                    surface  : picture.surface,
                    namedHost: host
                ))
            }
        }
        let region: HostedCaptureRegion?
        if case .hostedSheet = picture.role {
            guard let resolved = hostedCaptureRegion(for: picture.surface, role: picture.role)
            else { return .failure(.evidenceInsufficient(.absent(.geometryMissing))) }
            region = resolved
        } else {
            region = nil
        }
        let delivered = await captureAndIssue(
            surface            : picture.surface,
            role               : picture.role,
            region             : region,
            instance           : assignment.instance,
            selectionGeneration: chosen.generation,
            deadlineNanoseconds: deadlineNanoseconds,
            isMenu             : false
        )
        guard case .success(var delivery) = delivered, !elsewhere.isEmpty else { return delivered }
        delivery.causesElsewhere  = elsewhere
        delivery.shownOutsideSeat = windowsShownOutsideSeat(among: elsewhere)
        return .success(delivery)
    }

    /// The windows `causes` put outside the seat that the window server shows on
    /// screen right now, outside the Virtual Display: the one case the person
    /// can do anything about.
    ///
    /// A window its application hid or ordered out, one whose visibility did
    /// not decide inside the seat and one missing from the reading are none of
    /// them. Told about DaVinci Resolve's hidden Project Manager as though it
    /// were open, a worker stopped and asked the person to close a window
    /// nobody could see.
    private func windowsShownOutsideSeat(among causes: [SelectionSuspension]) -> [WindowIdentity] {
        var numbers: Set<Int> = []
        for case .containmentNotVerified(let blocks) in causes {
            for case .surfaceOutsideSeat(let number) in blocks { numbers.insert(number) }
        }
        return numbers.sorted().compactMap { number in
            guard let member = assignmentKit.inventory.surfaces[number],
                  member.presence == .outsideSeat, !member.isOrderedOut,
                  let shown = sensing.windowGeometry(of: number),
                  shown.identity == member.identity,
                  !sensing.virtualDisplayBounds.contains(shown.frame)
            else { return nil }
            return member.identity
        }
    }

    /// The Window IDs one observation of `selected` shows: the surface and
    /// every host its picture climbs to, as `observationPicture(for:)` climbs.
    private func observedWindowNumbers(of selected: WindowIdentity) -> Set<Int> {
        var numbers: Set<Int> = [selected.windowNumber]
        var current = selected
        while let host = selectionKit.attachedHost(of: current),
              numbers.insert(host.windowNumber).inserted {
            current = host
        }
        return numbers
    }

    /// Whether a cause speaks only of windows an observation does not show, so
    /// the observation goes ahead and carries it instead of being refused.
    ///
    /// A window of the application left on the person's screen, one whose
    /// visibility did not decide, one missing from the last reading and one
    /// whose move was refused are each a fact about that window and not about
    /// the one observed: DaVinci Resolve opens its Qt editors and menus where
    /// the person's pointer is, and each of them suspended the whole seat.
    /// Everything else still refuses: a modal block or a modal doubt, a reading
    /// that cannot carry the whole application, an attribution in doubt, and
    /// any cause about the observed surface itself. A handover deadline is the
    /// sum of the windows it waited for, so it goes with them.
    private nonisolated static func isElsewhere(
        _ cause           : SelectionSuspension,
        observing observed: Set<Int>
    ) -> Bool {

        switch cause {
            case .visibilityUncertain(let surface):
                return !observed.contains(surface.windowNumber)
            case .containmentNotVerified(let blocks):
                var namesAnotherWindow = false
                for block in blocks {
                    switch block {
                        case .surfaceOutsideSeat(let number), .surfaceAbsent(let number),
                             .surfaceUnverified(let number), .attemptSpent(let number),
                             .destinationUnusable(let number), .effectRefused(let number, _),
                             .surfaceDeadlineExpired(let number, _), .surfaceStalled(let number, _, _):
                            guard !observed.contains(number) else { return false }
                            namesAnotherWindow = true
                        case .handoverDeadlineExpired, .handoverStalled:
                            continue
                        case .notAssigned, .readingUnavailable, .inventoryNotQualified,
                             .attributionUncertain:
                            return false
                    }
                }
                return namesAnotherWindow
            default:
                return false
        }
    }

    /// Brings the Selected Target back on stage when the fold read it as a Stage
    /// Manager thumbnail, and answers the refusal when it cannot.
    ///
    /// What a capture of a stashed window delivers is the thumbnail, whose size
    /// is no constant: measured at 90 by 97 points and at 120 by 121. The agent
    /// would be shown that as its own scene and would decide coordinates on it,
    /// whatever it measured. So the stash is answered before the
    /// capture, once, inside the request's own deadline, and never by handing
    /// the pixels over with a note.
    ///
    /// A staging that fails is `captureFailed`: nothing was sampled and nothing
    /// was delivered, which is exactly what that case says, and `stage` has
    /// already reported `windowStashed` as the Issue. No case is added here,
    /// because none was missing.
    private func stageStashedTarget(
        _ surface      : WindowIdentity,
        within deadline: UInt64
    ) async -> ObservationUnavailable? {

        guard let record = session[surface.windowNumber], !record.isStaged else { return nil }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            return .captureDeadlineExpired(attemptsSpent: 0)
        }
        do { _ = try await stage(record.window) }
        catch {
            return .captureFailed(
                reason: "the stashed target could not be staged: \(String(describing: error))"
            )
        }
        return nil
    }

    /// True when one more reading can establish evidence that deliberately
    /// requires two agreeing observations, or when the seat's own detected
    /// window transaction can replace the assignment nucleus's refused direct
    /// move: the follower's for a window that appeared later, and
    /// `takeInRefusedPreexistingMembers` for one already open at the
    /// handover. Other permanent qualification gaps and spent budgets reach the
    /// caller's normal refusal.
    private func selectionNeedsConfirmingReading() -> Bool {

        guard case .suspended(_, let causes) = selectionKit.operability() else { return false }
        return causes.contains { cause in
            switch cause {
                case .noEligibleTarget, .selectedSurfaceNotVerified, .selectedSurfaceAbsent:
                    true
                case .containmentNotVerified(let blocks):
                    blocks.contains { block in
                        switch block {
                            case .surfaceUnverified, .surfaceOutsideSeat,
                                 .inventoryNotQualified:
                                true
                            case .effectRefused(_, let refusal):
                                if case .adapterNotQualified = refusal { true } else { false }
                            default:
                                false
                        }
                    }
                default:
                    false
            }
        }
    }

    /// A selected surface can already be geometrically confirmed while the
    /// follower has not registered it as a held member. Joining that lifecycle
    /// before issuing an observation prevents a later `recipientNotCurrent`
    /// after the picture was handed out. Native standalone panels can be
    /// `AXStandardWindow` with `AXModal = 0`, so this keeps the observed role
    /// separate from the narrowly-attested recovery relation below.
    private func selectedSurfaceNeedsOwnership() -> Bool {
        guard let selected = selectionKit.selected,
              case .ordinaryTarget = observationPicture(for: selected.surface).role
        else { return false }
        return session[selected.surface.windowNumber]?.window.reference.identity != selected.surface
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
    /// call. A source that has not qualified the menu surface refuses here
    /// before any effect, with the capability named; the shipped one has
    /// qualified it on the AppKit family.
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
        region             : HostedCaptureRegion? = nil,
        instance           : ProcessIdentity,
        selectionGeneration: UInt64,
        deadlineNanoseconds: UInt64,
        isMenu             : Bool
    ) async -> Result<SeatObservationDelivery, ObservationUnavailable> {

        let barrier = observationIssuer.barrier
        let captureTarget = region.map {
            SeatCaptureTarget.attestedWindowRegion(
                host              : $0.host,
                children          : $0.children,
                displayID         : displayID,
                screenRect        : $0.screenRect,
                sourceWindowFrame : $0.sourceWindowFrame
            )
        }
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
                    if let region {
                        frame = try await observationSource.captureWindowRegionStill(
                            host                : region.host,
                            children            : region.children,
                            displayID           : displayID,
                            screenRect          : region.screenRect,
                            sourceWindowFrame   : region.sourceWindowFrame,
                            observationBarrier  : barrier,
                            deadlineNanoseconds : deadlineNanoseconds
                        )
                    } else {
                        frame = try await observationSource.captureWindowStill(
                            of                 : surface,
                            observationBarrier : barrier,
                            deadlineNanoseconds: deadlineNanoseconds
                        )
                    }
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
            if let region,
               hostedCaptureRegion(for: surface, role: role) != region {
                return .failure(.suspended([.observationSuperseded(
                    observed: selectionGeneration,
                    current : selectionKit.selectionGeneration
                )]))
            }
            if let region,
               frame.geometry.screenRect != region.screenRect
                    || frame.geometry.sourceWindowFrame != region.sourceWindowFrame {
                return .failure(.evidenceInsufficient(.invalid(.geometryMalformed)))
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
                            geometry : qualified.geometry,
                            captureTarget: captureTarget
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
            // The operating surface is the selected one; `surface` is where the
            // pixels came from, which for a hosted sheet is its host.
            guard let selected = selectionKit.selected,
                  selected.generation == selectionGeneration,
                  observationPicture(for: selected.surface) == (surface, role)
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

    /// Reads the complete, already-attested host chain immediately before and
    /// after a hosted-sheet capture. Every member has to retain its identity
    /// and finite geometry; a missing proxy is never replaced by a convenient
    /// ordinary window.
    private func hostedCaptureRegion(
        for host: WindowIdentity,
        role: ObservedSurfaceRole
    ) -> HostedCaptureRegion? {
        guard case .hostedSheet(let logical) = role,
              let hostReading = sensing.windowGeometry(of: host.windowNumber),
              hostReading.identity == host,
              hostReading.frame.hasFinitePositiveArea
        else { return nil }

        var children: [WindowIdentity] = []
        var frames = [hostReading.frame]
        var visited: Set<WindowIdentity> = [host]
        var current = logical
        while current != host {
            guard visited.insert(current).inserted,
                  let reading = sensing.windowGeometry(of: current.windowNumber),
                  reading.identity == current,
                  reading.frame.hasFinitePositiveArea
            else { return nil }
            children.append(current)
            frames.append(reading.frame)
            guard let parent = selectionKit.attachedHost(of: current)
                    ?? selectionKit.namedModalHost(of: current)
            else { return nil }
            current = parent
        }
        let crop = frames.reduce(hostReading.frame) { $0.union($1) }
        guard crop.hasFinitePositiveArea,
              sensing.virtualDisplayBounds.contains(crop)
        else { return nil }
        return HostedCaptureRegion(
            host              : host,
            children          : children,
            screenRect        : crop,
            sourceWindowFrame : hostReading.frame
        )
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
        // Only the kind has to match here. The exact role is compared against
        // the live tree below, where a sheet that closed is a role that changed.
        guard reference.role.isTransientMenu == role.isTransientMenu else {
            if case .transientMenu(let parent) = reference.role {
                return .ordinaryCommandDuringMenu(parent: parent)
            }
            return .roleChanged
        }

        let liveSurface     : WindowIdentity
        let liveRole        : ObservedSurfaceRole
        let selectionMoment : UInt64

        switch reference.role {
            case .ordinaryTarget, .hostedSheet:
                guard let selected = selectionKit.selected else {
                    return .recipientNotCurrent(reference.recipient)
                }
                let picture     = observationPicture(for: selected.surface)
                liveSurface     = picture.surface
                liveRole        = picture.role
                selectionMoment = selected.generation

            case .transientMenu:
                guard let context = menuContext,
                      DispatchTime.now().uptimeNanoseconds < context.deadlineNanoseconds
                else { return .menuContextRevoked }
                liveSurface     = context.menuIdentity
                liveRole        = reference.role
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
            role                    : liveRole,
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
