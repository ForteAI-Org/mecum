//
//  CommandBornWindowTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

import CoreGraphics
import Foundation
import SeatCore
@testable import SeatSession
import Testing

/// A Command pressed inside a brief activation opens a panel of the target on the
/// person's display (ADR 0033), over the fakes and a recovery whose clock
/// a row can move forward by hand. The recovery's reports are routed to the seat, so a
/// `restoring` among them really moves it to `waiting`. No display, no Photoshop.
@MainActor
@Suite("A window the Command opened")
struct CommandBornWindowTests {

    private static let user = FakeGeometry.reference(
        frame       : CGRect(x: 100, y: 100, width: 600, height: 500),
        processID   : FakeGeometry.userPID,
        windowNumber: 801
    )
    private static let panelNumber       = AppWindowFollowTests.secondWindowNumber
    private static let secondPanelNumber = AppWindowFollowTests.thirdWindowNumber

    @MainActor
    private final class Rig {
        var requested: [WindowReference]         = []
        var reports  : [UserFocusRecoveryReport] = []
        /// Added to the real monotonic clock the recovery reads, so a row can
        /// move past the margin without waiting for it.
        var offset   : UInt64                    = 0
        var handbackWorks                        = true
        let sensing  = FakeSensing()
        let placing  = FakePlacing()
        var seat     : AgentSeat!
        var recovery : UserFocusRecovery!
        var target   : WindowReference { seat.currentTarget!.reference }
    }

    private static func rig(
        baseline: [WindowSurface] = [],
        marker  : Int64
    ) async throws -> Rig {
        let rig = Rig()
        rig.sensing.additionalWindows[user.windowNumber] = user
        rig.sensing.focusedUserWindow  = user
        rig.sensing.frontmostProcessID = user.processID
        let sender = FakeSender()
        let (seat, _) = try await AppWindowFollowTests.followingSeat(
            sensing : rig.sensing,
            placing : rig.placing,
            sender  : sender,
            marker  : marker,
            baseline: baseline
        )
        rig.seat = seat
        rig.recovery = UserFocusRecovery(
            sensing: rig.sensing,
            gate   : sender.gate,
            adopted: { [weak seat] in seat?.adoptedWindows.map(\.reference) ?? [] },
            restore: { [weak rig] window in
                guard let rig else { return 0 }
                rig.requested.append(window)
                if window.processID == user.processID, !rig.handbackWorks { return 0 }
                rig.sensing.frontmostProcessID = window.processID
                rig.sensing.focusedUserWindow  = window
                return 0
            },
            now    : { [weak rig] in DispatchTime.now().uptimeNanoseconds &+ (rig?.offset ?? 0) },
            changed: { [weak rig] report in
                guard let rig else { return }
                rig.reports.append(report)
                rig.seat.focusRecoveryChanged(report)
            }
        )
        seat.focusRecovery = rig.recovery
        return rig
    }

    /// The Command: a menu item pressed once on the target in front.
    private static func press(_ rig: Rig) async -> BriefActivationOutcome {
        await rig.seat.performMenuCommandBrieflyInFront(when: { true }, performOnce: {})
    }

    /// The panel the Command opens: born on the person's display, at the modal layer.
    @discardableResult
    private static func openPanel(_ rig: Rig, _ number: Int = panelNumber) -> WindowReference {
        AppWindowFollowTests.offer(number, to: rig.sensing, rig.placing, level: 8)
    }

    // MARK: Lever A, an activation that is the Command's effect

    @Test("the command's own notification arriving late, with the front already back, is no waiting")
    func aLateNotificationIsTheCommandsOwn() async throws {
        let rig = try await Self.rig(marker: 7_501)
        defer { rig.recovery.stop() }
        let outcome = await Self.press(rig)
        guard case .ready = outcome else { Issue.record("not ready: \(outcome)"); return }
        #expect(rig.requested == [rig.target, Self.user])

        // About 300 ms after the handback, with Photoshop never in front again.
        rig.recovery.activationChanged(to: rig.target.processID, source: .workspaceNotification)

        #expect(rig.reports.isEmpty, "nothing read it as the person's focus being taken")
        #expect(!rig.recovery.isPaused)
        #expect(rig.seat.state == .ready)
        #expect(rig.seat.inputPauseReasons.isEmpty)

        // The panel is born later on the person's display and moves in; the front
        // is already with the person, so there is nothing to hand back.
        Self.openPanel(rig)
        #expect(await AppWindowFollowTests.settle { rig.seat.adoptedWindows.count == 2 })
        await AppWindowFollowTests.pause(0.2)
        #expect(rig.requested == [rig.target, Self.user])
    }

    @Test("the target retaking the front for the panel is adopted with exactly one extra handback")
    func theTargetRetakingTheFrontForThePanel() async throws {
        let rig = try await Self.rig(marker: 7_502)
        defer { rig.recovery.stop() }
        let target = rig.target
        _ = await Self.press(rig)

        // Photoshop retakes the front by itself, before the panel exists.
        rig.sensing.frontmostProcessID = target.processID
        rig.recovery.activationChanged(to: target.processID, source: .workspaceNotification)
        #expect(rig.reports.isEmpty)
        #expect(rig.seat.state == .ready)

        Self.openPanel(rig)
        #expect(await AppWindowFollowTests.settle { rig.seat.adoptedWindows.count == 2 })
        #expect(await AppWindowFollowTests.settle { rig.requested.count == 3 })
        #expect(rig.requested == [target, Self.user, Self.user], "one handback, asked after the panel was adopted")
        await AppWindowFollowTests.pause(0.3)
        #expect(rig.sensing.frontmostProcessID == Self.user.processID)
        #expect(rig.reports.isEmpty)
        #expect(rig.seat.state == .ready)

        // A second window of the Command never earns a second handback.
        rig.sensing.frontmostProcessID = target.processID
        Self.openPanel(rig, Self.secondPanelNumber)
        rig.seat.heartbeat()
        #expect(await AppWindowFollowTests.settle { rig.seat.adoptedWindows.count == 3 })
        await AppWindowFollowTests.pause(0.2)
        #expect(rig.requested.count == 3)
    }

    @Test("the margin ending with the target still in front and no new window falls back to waiting")
    func theMarginExpiresWithTheTargetInFront() async throws {
        let rig = try await Self.rig(marker: 7_503)
        defer { rig.recovery.stop() }
        let target = rig.target
        _ = await Self.press(rig)
        rig.sensing.frontmostProcessID = target.processID
        rig.recovery.activationChanged(to: target.processID, source: .workspaceNotification)
        #expect(rig.reports.isEmpty)

        // Not yet over: nothing happens.
        await rig.recovery.settleCommandProvenance()
        #expect(rig.reports.isEmpty)

        rig.offset += CommandProvenance.marginNanoseconds
        await rig.recovery.settleCommandProvenance()

        #expect(rig.reports.first?.outcome == .restoring, "today's behaviour: the target's activation is the person's")
        #expect(rig.seat.state == .waiting)
        #expect(rig.requested == [target, Self.user], "no new window, so no extra handback")
        #expect(rig.recovery.commandProvenance == nil)
    }

    @Test("a panel that appeared while the follow pass did not run is sighted when the margin settles")
    func aPanelSeenOnlyByTheSettleRead() async throws {
        let rig = try await Self.rig(marker: 7_510)
        defer { rig.recovery.stop() }
        let target = rig.target
        _ = await Self.press(rig)

        // The follow pass stands down for the whole margin (another transfer is busy).
        rig.sensing.userMayBeSwitchingApplications = true
        rig.sensing.frontmostProcessID = target.processID
        rig.recovery.activationChanged(to: target.processID, source: .workspaceNotification)
        #expect(rig.reports.isEmpty)

        let panel = Self.openPanel(rig)
        await AppWindowFollowTests.pause(0.3)
        #expect(rig.seat.adoptedWindows.count == 1, "the pass did not take it in")
        #expect(rig.recovery.commandSighting(of: panel) == nil, "and nothing sighted it")

        // The margin ends and the person's intent is no longer recent: only the settle read sees the panel.
        rig.offset += CommandProvenance.marginNanoseconds
        rig.sensing.userMayBeSwitchingApplications = false
        await rig.recovery.settleCommandProvenance()

        #expect(rig.requested == [target, Self.user, Self.user], "exactly one extra handback")
        #expect(rig.sensing.frontmostProcessID == Self.user.processID)
        #expect(rig.reports.isEmpty)
        #expect(!rig.recovery.isPaused)
        #expect(rig.seat.state != .waiting)
        #expect(rig.recovery.commandProvenance == nil)
    }

    @Test("an activation of the target outside any record keeps producing waiting",
          arguments: [false, true])
    func aRealActivationOutsideTheRecordWaits(afterACommand: Bool) async throws {
        let rig = try await Self.rig(marker: afterACommand ? 7_504 : 7_505)
        defer { rig.recovery.stop() }
        let target = rig.target
        if afterACommand {
            _ = await Self.press(rig)
            rig.offset += CommandProvenance.marginNanoseconds
        }

        rig.sensing.frontmostProcessID = target.processID
        rig.recovery.activationChanged(to: target.processID, source: .workspaceNotification)

        #expect(rig.reports.first?.outcome == .restoring)
        #expect(rig.seat.state == .waiting)

        // The panel it opened is not the Command's, and the seat does not move it.
        let panel = Self.openPanel(rig)
        await AppWindowFollowTests.pause(0.4)
        #expect(rig.seat.adoptedWindows.count == 1)
        await #expect(throws: SessionFailure.self) { try await rig.seat.integrateDetectedWindow(panel) }
    }

    // MARK: Lever C, a window the Command opened while the seat waits

    @Test("a handback that failed with the Command's panel present adopts it and retries once")
    func aFailedHandbackWithThePanelPresent() async throws {
        let rig = try await Self.rig(marker: 7_506)
        defer { rig.recovery.stop() }
        let target = rig.target
        rig.handbackWorks = false

        let outcome = await Self.press(rig)

        #expect(outcome == .handbackNotVerified)
        #expect(rig.seat.state == .waiting)
        #expect(rig.recovery.episodeBeganDuringCommand)
        #expect(rig.requested == [target, Self.user])

        Self.openPanel(rig)
        rig.handbackWorks = true
        #expect(await AppWindowFollowTests.settle { rig.seat.adoptedWindows.count == 2 })
        #expect(await AppWindowFollowTests.settle { rig.requested.count == 3 })
        #expect(rig.requested == [target, Self.user, Self.user], "a single retry")
        #expect(rig.sensing.frontmostProcessID == Self.user.processID)

        // Taking the panel in left the seat waiting; the person's focus ends that.
        if rig.recovery.isPaused { rig.recovery.verify(); rig.recovery.verify() }
        #expect(rig.reports.last?.outcome == .restored)
        #expect(rig.seat.state == .ready)
        await AppWindowFollowTests.pause(0.2)
        #expect(rig.requested.count == 3)
    }

    @Test("the front counts as back only after the extra handback was verified and the target let go")
    func theFrontIsBackOnlyAfterAVerifiedReturn() async throws {
        let rig = try await Self.rig(marker: 7_509)
        defer { rig.recovery.stop() }
        #expect(!rig.seat.frontIsBackAfterCommand, "no Command pressed yet")
        rig.handbackWorks = false

        #expect(await Self.press(rig) == .handbackNotVerified)
        #expect(rig.seat.state == .waiting)
        #expect(!rig.seat.frontIsBackAfterCommand, "the recovery is paused and the target holds the front")

        Self.openPanel(rig)
        rig.handbackWorks = true
        #expect(await AppWindowFollowTests.settle { rig.requested.count == 3 })
        if rig.recovery.isPaused { rig.recovery.verify(); rig.recovery.verify() }
        #expect(rig.seat.state == .ready)
        #expect(await AppWindowFollowTests.settle { rig.seat.frontIsBackAfterCommand })

        // The target holding the front again, or a new press, ends it.
        rig.sensing.frontmostProcessID = rig.target.processID
        #expect(!rig.seat.frontIsBackAfterCommand)
        rig.sensing.frontmostProcessID = Self.user.processID
        #expect(rig.seat.frontIsBackAfterCommand)
        rig.handbackWorks = false
        _ = await Self.press(rig)
        #expect(!rig.seat.frontIsBackAfterCommand)
    }

    @Test("while the seat waits on the Command's episode, only the Command's own panel is admitted")
    func onlyTheCommandsOwnWindowIsAdmitted() async throws {
        let preexisting = AppWindowFollowTests.reference(780)
        let rig = try await Self.rig(
            baseline: [AppWindowFollowTests.surface(preexisting, level: 8)],
            marker  : 7_507
        )
        defer { rig.recovery.stop() }
        rig.handbackWorks = false
        _ = await Self.press(rig)
        #expect(rig.seat.state == .waiting)

        let stranger = AppWindowFollowTests.reference(790, processID: FakeGeometry.distinctProcessID())
        for refused in [stranger, preexisting] {
            await #expect(throws: SessionFailure.self) { try await rig.seat.integrateDetectedWindow(refused) }
        }

        Self.openPanel(rig)
        rig.handbackWorks = true
        #expect(await AppWindowFollowTests.settle { rig.seat.adoptedWindows.count == 2 })
        #expect(rig.seat.adoptedWindows.map(\.id).contains(Self.panelNumber))
        #expect(!rig.seat.adoptedWindows.map(\.id).contains(780))
    }

    @Test("a window first seen after the margin is not admitted while the seat waits")
    func aWindowAfterTheMarginIsNotAdmitted() async throws {
        let rig = try await Self.rig(marker: 7_508)
        defer { rig.recovery.stop() }
        rig.handbackWorks = false
        _ = await Self.press(rig)
        #expect(rig.seat.state == .waiting)

        rig.offset += CommandProvenance.marginNanoseconds
        let panel = Self.openPanel(rig)
        await AppWindowFollowTests.pause(0.5)

        #expect(rig.seat.adoptedWindows.count == 1)
        #expect(rig.recovery.commandSighting(of: panel) == nil)
        await #expect(throws: SessionFailure.self) { try await rig.seat.integrateDetectedWindow(panel) }
    }
}
