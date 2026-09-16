//
//  ContextMenuTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
//

import CoreGraphics
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// The contextual menu action, driven through the fakes.
///
/// What is under test here is the half a live run cannot assert reliably: that
/// the window server's answer is believed and nothing else is, that the
/// teardown runs on every path out of the action, and that a menu nothing could
/// close is the loudest failure the seat has.
///
/// The fakes model the menu's life rather than counting reads. The right click
/// makes the sensing show a menu window, the item click and the Preparation
/// cycle make it disappear, exactly as they do on a real machine, so a test
/// reads as the sequence it is testing.
@MainActor
@Suite("The contextual menu")
struct ContextMenuTests {

    static let openAt = InputLocation(
        screenPoint       : CGPoint(x: 2700, y: 700),
        windowPointFromTop: CGPoint(x: 100, y: 100)
    )

    /// A seat with a window adopted, a turn held, and a target whose right
    /// click opens a menu.
    ///
    /// `closedBy` says which of the levers the target answers to, which is the
    /// whole variable of this suite: a target that answers the item click, one
    /// that only answers the Preparation cycle, one that only answers Escape,
    /// and one that answers nothing.
    private static func ready(
        opensAMenu: Bool = true,
        closedBy  : Set<ContextMenuReceipt.Closure> = [.chosenItem, .preparationCycle, .escapeKey]
    ) async throws -> (
        seat: AgentSeat, window: AdoptedWindow, turn: Turn,
        sensing: FakeSensing, sender: FakeSender
    ) {

        let sensing = FakeSensing()
        let sender  = FakeSender()

        sender.onSend = { command in
            switch command {
                case .click(_, .right):
                    if opensAMenu { sensing.menus = [FakeGeometry.menuWindow] }
                case .click(_, .left):
                    if closedBy.contains(.chosenItem) { sensing.menus = [] }
                case .key(53, _, _):
                    if closedBy.contains(.escapeKey) { sensing.menus = [] }
                default:
                    break
            }
        }
        sender.onCyclePreparation = {
            if closedBy.contains(.preparationCycle) { sensing.menus = [] }
        }

        let seat   = makeSeat(sensing: sensing, sender: sender)
        let window = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        let turn   = try await seat.acquire()
        return (seat, window, turn, sensing, sender)
    }

    // MARK: Opening

    @Test("the click that opens a menu is a right click, and the menu comes back as a rectangle")
    func opensWithARightClick() async throws {

        let context = try await Self.ready()

        let receipt = try await context.seat.useContextMenu(
            openedAt: Self.openAt, of: context.window, turn: context.turn
        )

        #expect(context.sender.sent.first?.command == .click(Self.openAt, button: .right))
        #expect(receipt.menu.window.windowNumber == FakeGeometry.menuWindowNumber)
        #expect(receipt.menu.frame == FakeGeometry.menuWindow.frame)
        #expect(receipt.chosenPoint == nil)
        #expect(context.seat.state == .ready)
    }

    @Test("a menu that never appears is a refusal, not an assumption")
    func neverOpenedRefuses() async throws {

        let context = try await Self.ready(opensAMenu: false)

        await #expect(throws: SessionFailure.contextMenuNeverOpened(
            windowNumber: FakeGeometry.windowNumber,
            within      : .milliseconds(90)
        )) {
            try await context.seat.useContextMenu(
                openedAt: Self.openAt,
                of      : context.window,
                turn    : context.turn,
                within  : .milliseconds(90)
            )
        }
        // The click did go out, which is why this is a refusal of the action
        // and never a claim that nothing happened.
        #expect(context.sender.sent.count == 1)
        #expect(context.seat.state == .ready)
    }

    @Test("a failed timeout cleanup stays visible without replaying the opening click")
    func failedTimeoutCleanupDegrades() async throws {
        let context = try await Self.ready(opensAMenu: false)
        context.sender.cycleError = InputPreparationFailure(
            progress: InputProgress(
                completedSteps              : [.activation, .keyWindowFirst, .keyWindowSecond],
                failedStep                  : .restore,
                failedStepMayHaveTakenEffect: true,
                cleanup                     : .failed(code: -17)
            ),
            cause       : InputFailure.restoreFailed(code: -17),
            cleanupCause: InputFailure.restoreFailed(code: -17)
        )

        await #expect(throws: SessionFailure.contextMenuNeverOpened(
            windowNumber: FakeGeometry.windowNumber,
            within      : .milliseconds(90)
        )) {
            try await context.seat.useContextMenu(
                openedAt: Self.openAt,
                of      : context.window,
                turn    : context.turn,
                within  : .milliseconds(90)
            )
        }

        #expect(context.sender.sent.count == 1)
        #expect(context.sender.preparationCycles == [FakeGeometry.windowNumber])
        #expect(context.seat.state == .degraded)
    }

    @Test("a menu already open refuses before the click, because the click would go to it")
    func alreadyOpenRefuses() async throws {

        let context = try await Self.ready()
        context.sensing.menus = [FakeGeometry.menuWindow]

        await #expect(throws: SessionFailure.contextMenuAlreadyOpen(
            processID: FakeGeometry.targetPID
        )) {
            try await context.seat.useContextMenu(
                openedAt: Self.openAt, of: context.window, turn: context.turn
            )
        }
        #expect(context.sender.sent.isEmpty, "nothing was posted at all")
    }

    // MARK: Choosing

    @Test("the item click is a left click routed to the menu's own window")
    func theItemClickGoesToTheMenu() async throws {

        let context = try await Self.ready()

        let receipt = try await context.seat.useContextMenu(
            openedAt: Self.openAt,
            of      : context.window,
            turn    : context.turn
        ) { menu in
            CGPoint(x: menu.frame.width / 2, y: menu.frame.height / 2)
        }

        #expect(receipt.chosenPoint == CGPoint(x: 57.5, y: 17))
        #expect(receipt.closedBy == .chosenItem)
        #expect(context.sender.sent.count == 2, "no teardown event was needed")

        guard case .click(let location, let button) = context.sender.sent[1].command else {
            Issue.record("the second command was not a click")
            return
        }
        #expect(button == .left)
        #expect(location.windowPointFromTop == CGPoint(x: 57.5, y: 17))
        // The screen point is the menu's own frame plus the point: the window
        // server's frame is the only reading a menu window has.
        #expect(location.screenPoint == CGPoint(
            x: FakeGeometry.menuWindow.frame.minX + 57.5,
            y: FakeGeometry.menuWindow.frame.minY + 17
        ))
    }

    @Test("answering nil chooses nothing, and the menu is closed anyway")
    func choosingNothingStillCloses() async throws {

        let context = try await Self.ready()

        let receipt = try await context.seat.useContextMenu(
            openedAt: Self.openAt, of: context.window, turn: context.turn
        )

        #expect(receipt.choosing == nil)
        #expect(receipt.closedBy == .preparationCycle)
        #expect(context.sender.preparationCycles == [FakeGeometry.windowNumber])
    }

    // MARK: The teardown

    @Test("the preparation cycle is the first lever, and it is pulled on the target")
    func theCycleIsTheFirstLever() async throws {

        let context = try await Self.ready(closedBy: [.preparationCycle])

        let receipt = try await context.seat.useContextMenu(
            openedAt: Self.openAt, of: context.window, turn: context.turn
        )

        #expect(receipt.closedBy == .preparationCycle)
        // The cycle goes to the target's window and never to the menu's: what
        // the tracking loop watches is the target's own application state.
        #expect(context.sender.preparationCycles == [FakeGeometry.windowNumber])
        #expect(!context.sender.sent.contains { command, _ in
            command == .key(virtualKey: 53, text: "", flags: [])
        }, "no escape was needed, so none was posted")
    }

    @Test("an escape is the second net, and it is routed to the target's process")
    func escapeIsTheSecondNet() async throws {

        let context = try await Self.ready(closedBy: [.escapeKey])

        let receipt = try await context.seat.useContextMenu(
            openedAt: Self.openAt, of: context.window, turn: context.turn
        )

        #expect(receipt.closedBy == .escapeKey)
        #expect(context.sender.preparationCycles == [FakeGeometry.windowNumber])
        #expect(context.sender.sent.contains { command, _ in
            command == .key(virtualKey: 53, text: "", flags: [])
        })
    }

    @Test("a failed cycle cleanup remains visible after escape closes the menu")
    func failedCycleCleanupDegrades() async throws {
        let context = try await Self.ready(closedBy: [.escapeKey])
        context.sender.cycleError = InputPreparationFailure(
            progress: InputProgress(
                completedSteps              : [.activation, .keyWindowFirst, .keyWindowSecond],
                failedStep                  : .restore,
                failedStepMayHaveTakenEffect: true,
                cleanup                     : .failed(code: -17)
            ),
            cause       : InputFailure.restoreFailed(code: -17),
            cleanupCause: InputFailure.restoreFailed(code: -17)
        )

        let receipt = try await context.seat.useContextMenu(
            openedAt: Self.openAt,
            of      : context.window,
            turn    : context.turn
        )

        #expect(receipt.closedBy == .escapeKey)
        #expect(context.seat.state == .degraded)
    }

    @Test("a target that dismissed its own menu is said to have done so")
    func aMenuThatWentAwayOnItsOwn() async throws {

        let context = try await Self.ready()

        // The menu opens, the caller looks at it and chooses nothing, and the
        // target has dropped it by the time the teardown looks: an application
        // switch does exactly this.
        let receipt = try await context.seat.useContextMenu(
            openedAt: Self.openAt,
            of      : context.window,
            turn    : context.turn
        ) { _ in
            context.sensing.menus = []
            return nil
        }

        #expect(receipt.closedBy == .dismissedItself)
        #expect(context.sender.preparationCycles.isEmpty, "no lever was pulled at all")
    }

    @Test("a menu nothing closes is the loudest failure the action has")
    func aMenuLeftOpenIsCritical() async throws {

        let context = try await Self.ready(closedBy: [])

        var issues: [SeatIssue] = []
        let listening = Task { @MainActor in
            for await event in context.seat.events {
                if case .issueDetected(let issue, _) = event { issues.append(issue) }
            }
        }
        defer { listening.cancel() }

        await #expect(throws: SessionFailure.contextMenuNotClosed(
            menuWindowNumber: FakeGeometry.menuWindowNumber,
            processID       : FakeGeometry.targetPID
        )) {
            try await context.seat.useContextMenu(
                openedAt: Self.openAt, of: context.window, turn: context.turn
            )
        }

        // Both levers were pulled before it gave up.
        #expect(context.sender.preparationCycles == [FakeGeometry.windowNumber])
        #expect(context.sender.sent.contains { command, _ in
            command == .key(virtualKey: 53, text: "", flags: [])
        })

        for _ in 0 ..< 20 { await Task.yield() }
        #expect(issues.contains(.contextMenuLeftOpen))
        #expect(SeatIssue.contextMenuLeftOpen.isCritical)
    }

    @Test("the menu is closed even when the item click was refused, and the refusal survives")
    func closingWinsOverAFailedChoice() async throws {

        let context = try await Self.ready(closedBy: [.preparationCycle])
        context.sender.refusedCommand = { command in
            if case .click(_, .left) = command { return InputFailure.invalidLocation }
            return nil
        }

        await #expect(throws: InputFailure.invalidLocation) {
            try await context.seat.useContextMenu(
                openedAt: Self.openAt, of: context.window, turn: context.turn
            ) { _ in CGPoint(x: 10, y: 10) }
        }
        #expect(context.sender.preparationCycles == [FakeGeometry.windowNumber],
                "the teardown ran although the choice threw")
    }
}
