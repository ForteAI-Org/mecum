//
//  BriefActivationTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/09/2026.
//

import CoreGraphics
import SeatCore
@testable import SeatSession
import Testing

/// The seat bringing its target in front on purpose (ADR 0013), over the fakes and a focus
/// recovery built on them, whose requests move the front the way a real one does. The recovery's
/// reports are recorded rather than routed to the seat: a `restoring` among them is exactly what
/// would move the seat to `waiting`. No display, no window of a person's.
@MainActor
@Suite("A moment in front, on purpose")
struct BriefActivationTests {

    private static let user = FakeGeometry.reference(
        frame       : CGRect(x: 100, y: 100, width: 600, height: 500),
        processID   : FakeGeometry.userPID,
        windowNumber: 801
    )

    /// What the recovery was asked and what it said.
    @MainActor
    private final class Record {
        var requested: [WindowReference]         = []
        var briefRequested: [WindowReference]    = []
        var reports  : [UserFocusRecoveryReport] = []
    }

    private static func seat(
        sensing          : FakeSensing,
        requestsActivate : Bool = true,
        hasBriefRestorer : Bool = false,
        handbackIsReadable: Bool = true
    ) async throws -> (seat: AgentSeat, record: Record, recovery: UserFocusRecovery) {
        sensing.additionalWindows[user.windowNumber] = user
        sensing.focusedUserWindow = user
        sensing.frontmostProcessID = user.processID
        let sender = FakeSender()
        let (seat, _) = try await MultiWindowTests.seat(sensing: sensing, sender: sender)
        let record = Record()
        let recovery = UserFocusRecovery(
            sensing: sensing,
            gate   : sender.gate,
            adopted: { [weak seat] in seat?.adoptedWindows.map(\.reference) ?? [] },
            restore: { window in
                record.requested.append(window)
                if requestsActivate {
                    sensing.frontmostProcessID = window.processID
                    sensing.focusedUserWindow = window.processID == user.processID && !handbackIsReadable
                        ? nil : window
                }
                return 0
            },
            restoreForBriefActivation: hasBriefRestorer ? { window in
                record.briefRequested.append(window)
                sensing.frontmostProcessID = window.processID
                sensing.focusedUserWindow = window
                return 0
            } : nil,
            changed: { record.reports.append($0) }
        )
        seat.focusRecovery = recovery
        return (seat, record, recovery)
    }

    @Test("the target is in front until the condition holds, the front goes back once, and the seat never waits")
    func normalCase() async throws {
        let sensing = FakeSensing()
        let (seat, record, recovery) = try await Self.seat(sensing: sensing)
        let log = MultiWindowTests.EventLog(seat)
        defer { log.stop() }
        let before = seat.state
        let target = try #require(seat.currentTarget).reference
        // The stream buffers the adoption's own transitions; only what follows counts.
        await log.drain()
        let adoption = log.events.count

        var reads = 0
        let outcome = await seat.bringTargetBrieflyInFront(until: {
            reads += 1
            // The workspace notification of the seat's own request.
            if reads == 1 { recovery.activationChanged(to: target.processID) }
            return reads == 2
        })
        await log.drain()

        guard case .ready = outcome else { Issue.record("not ready: \(outcome)"); return }
        #expect(record.requested == [target, Self.user], "in front once, and the handback asked once")
        #expect(record.reports.isEmpty, "nothing read the seat's own activation as the person's focus taken")
        #expect(seat.inputPauseReasons.isEmpty, "the gate never closed")
        #expect(seat.state == before)
        let states = log.events.dropFirst(adoption).compactMap { event -> SeatState? in
            guard case .seatStateChanged(_, let to, _) = event else { return nil }
            return to
        }
        #expect(!states.contains(.waiting))
        #expect(states == [.acting, before], "acting for the length of it, like a Command")
    }

    @Test("Enabled readiness cannot succeed when an acknowledged front request never activates the target")
    func readinessRequiresTheObservedForeground() async throws {
        let sensing = FakeSensing()
        let (seat, record, _) = try await Self.seat(sensing: sensing, requestsActivate: false)
        let target = try #require(seat.currentTarget).reference
        var checks = 0
        let outcome = await seat.bringTargetBrieflyInFront(
            until: { checks += 1; return true }, atMost: .milliseconds(250)
        )
        guard case .notReady = outcome else { Issue.record("False readiness: \(outcome)"); return }
        #expect(checks == 0, "Readiness belongs to the requested foreground")
        #expect(record.requested == [target])
        #expect(sensing.frontmostProcessID == Self.user.processID)
        #expect(record.reports.isEmpty)
        #expect(seat.inputPauseReasons.isEmpty)
    }

    @Test("A readiness callback after the brief activation deadline cannot authorize a command")
    func anExpiredReadinessCallbackNeverRuns() async throws {
        let sensing = FakeSensing()
        let (seat, record, _) = try await Self.seat(sensing: sensing)
        let target = try #require(seat.currentTarget).reference
        var checks = 0
        let outcome = await seat.bringTargetBrieflyInFront(
            until: { checks += 1; return true }, atMost: .milliseconds(1)
        )
        guard case .notReady = outcome else { Issue.record("Late readiness: \(outcome)"); return }
        #expect(checks == 0)
        #expect(record.requested == [target, Self.user])
        #expect(sensing.frontmostProcessID == Self.user.processID)
        #expect(seat.inputPauseReasons.isEmpty)
    }

    @Test("A brief activation and its handback use their scoped restorer, preserving the ordinary route")
    func briefRequestsUseTheirScopedRestorer() async throws {
        let sensing = FakeSensing()
        let (seat, record, _) = try await Self.seat(sensing: sensing, hasBriefRestorer: true)
        let target = try #require(seat.currentTarget).reference
        let outcome = await seat.bringTargetBrieflyInFront(until: { true })
        guard case .ready = outcome else { Issue.record("Not ready: \(outcome)"); return }
        #expect(record.requested.isEmpty)
        #expect(record.briefRequested == [target, Self.user])
        #expect(sensing.frontmostProcessID == Self.user.processID)
        #expect(seat.inputPauseReasons.isEmpty)
    }

    @Test("Returning to the person's process without its attested window cannot report readiness")
    func anUnreadableHandbackIsNotReadiness() async throws {
        let sensing = FakeSensing()
        let (seat, record, _) = try await Self.seat(
            sensing: sensing,
            handbackIsReadable: false
        )
        let target = try #require(seat.currentTarget).reference
        #expect(await seat.bringTargetBrieflyInFront(until: { true }) == .handbackNotVerified)
        #expect(record.requested == [target, Self.user])
        #expect(sensing.frontmostProcessID == Self.user.processID)
        #expect(record.reports.isEmpty, "No new focus recovery may override the person's process")
        #expect(seat.inputPauseReasons.isEmpty)
    }

    @Test("with no window of the person's in front it refuses by name and brings nothing in front")
    func refusesWithoutADestination() async throws {
        let sensing = FakeSensing()
        let (seat, record, _) = try await Self.seat(sensing: sensing)
        sensing.focusedUserWindow = nil
        let before = seat.state

        let outcome = await seat.bringTargetBrieflyInFront(until: { true })

        #expect(outcome == .refused(.noUserWindow))
        #expect(record.requested.isEmpty)
        #expect(record.reports.isEmpty)
        #expect(seat.state == before)
    }

    @Test("a dialog of the application open in the seat refuses by name, and a closed one no longer does")
    func refusesWhileADialogIsOpen() async throws {
        let sensing = FakeSensing()
        let (seat, record, _) = try await Self.seat(sensing: sensing)
        let dialog = try #require(seat.currentTarget?.reference.identity)
        seat.selectionKit.declareModal(ModalRelationClaim(
            modal     : dialog,
            scope     : .application,
            provenance: .qualifiedModalAttestation
        ))
        #expect(seat.selectionKit.isApplicationModal(dialog))
        let before = seat.state

        #expect(await seat.bringTargetBrieflyInFront(until: { true }) == .refused(.dialogOpen))
        #expect(record.requested.isEmpty, "nothing was brought in front")
        #expect(record.reports.isEmpty)
        #expect(seat.state == before)

        // Gone from the window server, the dialog stops refusing before the inventory reads again.
        sensing.geometry = nil
        let outcome = await seat.bringTargetBrieflyInFront(until: { true })
        guard case .ready = outcome else { Issue.record("a closed dialog still refused: \(outcome)"); return }
    }

    @Test("the dialogs open in the seat are each held modal once, and a closed one drops out")
    func openDialogsAreTheLiveHeldModals() async throws {
        let sensing = FakeSensing()
        let (seat, windows) = try await MultiWindowTests.seat(
            sensing: sensing,
            also   : [MultiWindowTests.secondWindowNumber, MultiWindowTests.thirdWindowNumber]
        )
        #expect(seat.openDialogs.isEmpty, "no window is a modal yet")
        let dialogs = try windows.dropFirst().map { try #require($0.reference.identity) }
        for dialog in dialogs {
            seat.selectionKit.declareModal(ModalRelationClaim(
                modal     : dialog,
                scope     : .application,
                provenance: .qualifiedModalAttestation
            ))
        }
        #expect(seat.openDialogs == dialogs)

        sensing.additionalWindows[MultiWindowTests.secondWindowNumber] = nil
        #expect(seat.openDialogs == [dialogs[1]], "gone from the window server, it is no longer searched")
    }

    @Test("a seat with no focus recovery refuses by name")
    func refusesWithoutARecovery() async throws {
        let (seat, _) = try await MultiWindowTests.seat()
        #expect(await seat.bringTargetBrieflyInFront(until: { true }) == .refused(.noFocusRecovery))
    }

    @Test("a withdrawn modal is not open even when its WindowServer identity survives")
    func retainedWithdrawnModalIsNotOpen() async throws {
        let sensing = FakeSensing()
        let (seat, windows) = try await MultiWindowTests.seat(
            sensing: sensing, also: [MultiWindowTests.secondWindowNumber]
        )
        let dialog = try #require(windows.last?.reference.identity)
        seat.selectionKit.declareModal(ModalRelationClaim(
            modal: dialog, scope: .application, provenance: .qualifiedModalAttestation
        ))
        #expect(seat.openDialogs == [dialog])
        seat.selectionKit.observeVisibility(SurfaceVisibilityClaim(
            surface: dialog, state: .withdrawnEstablished, provenance: .qualifiedVisibilityAttestation
        ))
        #expect(sensing.windowGeometry(of: dialog.windowNumber)?.identity == dialog)
        #expect(seat.openDialogs.isEmpty)
        seat.selectionKit.observeVisibility(SurfaceVisibilityClaim(
            surface: dialog, state: .uncertain, provenance: .qualifiedVisibilityAttestation
        ))
        #expect(seat.openDialogs == [dialog], "an unreadable presentation continues to block activation")
    }

}
