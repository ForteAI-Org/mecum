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

/// The scoped menu interaction, driven through the fakes.
///
/// What is under test here is the half a live run cannot assert reliably: that
/// the window server's answer is believed and nothing else is, that the cleanup
/// runs on every path out of the interaction, that a menu nothing could close is
/// the loudest failure the seat has, and that the context carries no authority
/// once the interaction is over.
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
    static func ready(
        opensAMenu: Bool = true,
        closedBy  : Set<ContextMenuReceipt.Closure> = [.chosenItem, .preparationCycle, .escapeKey],
        profile   : ObservationProfile = .initialLab
    ) async throws -> (
        seat: AgentSeat, window: AdoptedWindow, turn: Turn,
        sensing: FakeSensing, sender: FakeSender, source: ControlledObservationSource
    ) {

        let sensing = FakeSensing()
        let sender  = FakeSender()

        // The menu window is readable like any other surface, and the reader
        // names it a contextual menu, which is what keeps it out of the history
        // of targets rather than a filter on the window level.
        sensing.additionalWindows[FakeGeometry.menuWindowNumber] = FakeGeometry.menuWindow
        let reader = ControlledSurfaceReader(sensing: sensing)
        reader.roles[FakeGeometry.menuWindowNumber] = .contextualMenu
        let source = ControlledObservationSource(sensing: sensing)

        sender.onSend = { command in
            switch command {
                case .click(_, .right, _):
                    if opensAMenu { sensing.menus = [FakeGeometry.menuWindow] }
                case .click(_, .left, _):
                    if closedBy.contains(.chosenItem) { sensing.menus = [] }
                case .key(53, _, _, _, _):
                    if closedBy.contains(.escapeKey) { sensing.menus = [] }
                default:
                    break
            }
        }
        sender.onCyclePreparation = {
            if closedBy.contains(.preparationCycle) { sensing.menus = [] }
        }

        let seat = makeSeat(
            sensing: sensing,
            sender : sender,
            reader : reader,
            source : source,
            profile: profile
        )
        let window = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        let turn   = try await seat.acquire()
        return (seat, window, turn, sensing, sender, source)
    }

    // MARK: Opening

    @Test("the click that opens a menu is a right click, and the menu comes back as a rectangle")
    func opensWithARightClick() async throws {

        let context = try await Self.ready()

        let outcome = try await context.seat.withContextMenu(
            openedAt   : Self.openAt,
            observation: try await observedReference(context.seat),
            turn       : context.turn
        )

        #expect(context.sender.sent.first?.command == .click(Self.openAt, button: .right))
        #expect(outcome.menu.window.windowNumber == FakeGeometry.menuWindowNumber)
        #expect(outcome.menu.frame == FakeGeometry.menuWindow.frame)
        #expect(outcome.insideMenu.isEmpty)
        #expect(!outcome.interactionExpired)
        #expect(context.seat.state == .ready)
    }

    @Test("a menu that never appears is a refusal, not an assumption")
    func neverOpenedRefuses() async throws {

        let context = try await Self.ready(opensAMenu: false)
        let observation = try await observedReference(context.seat)

        await #expect(throws: SessionFailure.contextMenuNeverOpened(
            windowNumber: FakeGeometry.windowNumber,
            within      : .milliseconds(90)
        )) {
            try await context.seat.withContextMenu(
                openedAt       : Self.openAt,
                observation    : observation,
                turn           : context.turn,
                appearingWithin: .milliseconds(90)
            )
        }
        // The click did go out, which is why this is a refusal of the action
        // and never a claim that nothing happened.
        #expect(context.sender.sent.count == 1)
        #expect(context.seat.state == .ready)
    }

    @Test("an opening geometry changed during preparation posts no context-menu click")
    func openingGeometryChangedAtTheFinalBoundaryPostsNothing() async throws {
        let context = try await Self.ready()
        let observation = try await observedReference(context.seat)

        // The sender's wait stands for the preparation the platform performs.
        // The opening callback must read this immediately before its first
        // post, not before the wait, because the right click cannot be replayed.
        context.sender.onSendWait = { context.sensing.geometry = nil }

        await #expect(throws: ObservationAdmissionRefusal.geometryChanged) {
            try await context.seat.withContextMenu(
                openedAt   : Self.openAt,
                observation: observation,
                turn       : context.turn
            )
        }
        #expect(context.sender.sent.isEmpty)
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
        let observation = try await observedReference(context.seat)

        await #expect(throws: SessionFailure.contextMenuNeverOpened(
            windowNumber: FakeGeometry.windowNumber,
            within      : .milliseconds(90)
        )) {
            try await context.seat.withContextMenu(
                openedAt       : Self.openAt,
                observation    : observation,
                turn           : context.turn,
                appearingWithin: .milliseconds(90)
            )
        }

        #expect(context.sender.sent.count == 1)
        #expect(context.sender.preparationCycles == [FakeGeometry.windowNumber])
        #expect(context.seat.state == .degraded)
    }

    @Test("a menu already open that no lever closes refuses before the click, because the click would go to it")
    func alreadyOpenRefuses() async throws {

        let context = try await Self.ready(closedBy: [])
        let observation = try await observedReference(context.seat)
        context.sensing.menus = [FakeGeometry.menuWindow]

        await #expect(throws: SessionFailure.contextMenuAlreadyOpen(
            processID: FakeGeometry.targetPID
        )) {
            try await context.seat.withContextMenu(
                openedAt   : Self.openAt,
                observation: observation,
                turn       : context.turn
            )
        }
        #expect(!context.sender.sent.contains { if case .click = $0.command { true } else { false } },
                "no click was posted at all")
        #expect(context.sender.preparationCycles == [FakeGeometry.windowNumber], "the closing levers were pulled")
    }

    @Test("a menu left open by an earlier right click is closed first, and the action opens its own")
    func aStaleMenuIsClosedFirst() async throws {

        let context = try await Self.ready()
        let observation = try await observedReference(context.seat)
        context.sensing.menus = [FakeGeometry.menuWindow]

        let outcome = try await context.seat.withContextMenu(
            openedAt   : Self.openAt,
            observation: observation,
            turn       : context.turn
        )

        #expect(context.sender.preparationCycles == [FakeGeometry.windowNumber, FakeGeometry.windowNumber],
                "one cycle closed the stale menu before the right click, one closed the action's own")
        #expect(context.sender.sent.first?.command == .click(Self.openAt, button: .right))
        #expect(outcome.menu.window.windowNumber == FakeGeometry.menuWindowNumber)
        #expect(context.seat.state == .ready)
    }

    @Test("a key while a menu of the window's process is open goes to the menu, unprepared, with no focus asked")
    func aKeyGoesToTheOpenMenu() async throws {

        let sensing   = FakeSensing()
        let sender    = FakeSender()
        let discovery = GestureEndpointRoutingTests.Discovery()
        // Finder's list answers no Window ID for its focus, so the window's keyboard discovery refuses.
        discovery.keyboardAnswer = .failure(.subtreeUnreadable(surface: FakeGeometry.identity()))
        let seat = makeSeat(
            sensing  : sensing,
            sender   : sender,
            marker   : 3_301,
            reader   : ControlledSurfaceReader(sensing: sensing),
            source   : ControlledObservationSource(sensing: sensing),
            clock    : ControlledContentClock(),
            endpoints: discovery.discovery
        )
        _ = try await seat.adopt(FakeGeometry.userSeatWindow, platform: ChromiumPlatform())
        let turn = try await seat.acquire()

        await #expect(throws: InputEndpointRefusal.self, "without a menu the keys need a focus to go to") {
            try await seat.send(.text("Compress"), observation: try await observedReference(seat), turn: turn)
        }
        sensing.menus = [FakeGeometry.menuWindow]
        let resolutions = discovery.keyboardResolutions
        let receipt = try await seat.send(.text("Compress"), observation: try await observedReference(seat), turn: turn)

        #expect(sender.sent.map(\.command) == [.text("Compress")])
        #expect(sender.addressed.last?.platform is AppKitPlatform, "a prepared recipe would close the menu")
        #expect(discovery.keyboardResolutions == resolutions)
        try seat.confirm(receipt, .unknown)
        try seat.release(turn)
    }

    // MARK: Choosing

    @Test("the item click is a left click routed to the menu's own window")
    func theItemClickGoesToTheMenu() async throws {

        let context = try await Self.ready()
        var observedRole: ObservedSurfaceRole?

        let outcome = try await context.seat.withContextMenu(
            openedAt   : Self.openAt,
            observation: try await observedReference(context.seat),
            turn       : context.turn
        ) { interaction in
            guard case .success(let delivery) = await interaction.observe() else { return }
            observedRole = delivery.role
            let frame = delivery.geometry.window.frame
            guard let point = InputLocation(
                screenPoint: CGPoint(x: frame.minX + 57.5, y: frame.minY + 17),
                observedIn : delivery.geometry
            ) else { return }
            do {
                _ = try await interaction.send(
                    .click(point, button: .left),
                    observation: delivery.reference
                )
            } catch {
                Issue.record("the item click was refused: \(error)")
            }
        }

        #expect(observedRole == .transientMenu(parent: FakeGeometry.identity()))
        #expect(outcome.insideMenu.count == 1)
        #expect(outcome.cleanup == .verifiedClosed(.chosenItem))
        #expect(context.sender.sent.count == 2, "no teardown event was needed")

        guard case .click(let location, let button, _) = context.sender.sent[1].command else {
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

    @Test("the menu surface cannot be observed where the capability is unqualified")
    func menuSurfaceCaptureIsRefusedWhenUnqualified() async throws {

        let context = try await Self.ready()
        context.source.supported.remove(.menuSurfaceStill)
        var refusal: ObservationUnavailable?

        let outcome = try await context.seat.withContextMenu(
            openedAt   : Self.openAt,
            observation: try await observedReference(context.seat),
            turn       : context.turn
        ) { interaction in
            if case .failure(let reason) = await interaction.observe() { refusal = reason }
        }

        // The gate belongs to the source and not to the seat, so a source that
        // answers false still refuses before any effect.
        #expect(refusal == .capabilityUnqualified(.menuSurfaceStill))
        #expect(outcome.insideMenu.isEmpty)
        #expect(outcome.cleanup == .verifiedClosed(.preparationCycle))

        // The shipped source is on the qualified side of that same gate, which
        // is what lets the chain this suite exercises be reached in a shipment.
        #expect(SeatCaptureObservationSource(displayGeneration: 1).supports(.menuSurfaceStill))
    }

    @Test("an ordinary Command on the parent is refused while a menu is the observation")
    func ordinaryCommandOnTheParentIsRefused() async throws {

        let context = try await Self.ready()
        var refusal: (any Error)?

        _ = try await context.seat.withContextMenu(
            openedAt   : Self.openAt,
            observation: try await observedReference(context.seat),
            turn       : context.turn
        ) { interaction in
            guard case .success(let delivery) = await interaction.observe() else { return }
            do {
                _ = try await context.seat.send(
                    .click(Self.openAt),
                    observation: delivery.reference,
                    turn       : context.turn
                )
            } catch { refusal = error }
        }

        #expect(refusal as? ObservationAdmissionRefusal == .ordinaryCommandDuringMenu(
            parent: FakeGeometry.identity()
        ))
    }

    @Test("a context kept past its interaction carries no authority")
    func aKeptContextIsRevoked() async throws {

        let context = try await Self.ready()
        var escaped: SeatMenuInteraction?

        _ = try await context.seat.withContextMenu(
            openedAt   : Self.openAt,
            observation: try await observedReference(context.seat),
            turn       : context.turn
        ) { interaction in
            escaped = interaction
        }

        let kept = try #require(escaped)
        #expect(kept.isRevoked)
        guard case .failure(let reason) = await kept.observe() else {
            Issue.record("a revoked context answered an observation")
            return
        }
        #expect(reason == .menuContextRevoked)
    }

    @Test("an expired interaction revokes the context and the cleanup still runs")
    func anExpiredInteractionIsRevoked() async throws {

        let expiring = try ObservationProfile.configured(
            frameAgeLimitNanoseconds  : 120_000_000_000,
            captureDeadlineNanoseconds: 5_000_000_000,
            captureAttempts           : 2,
            menuInteractionNanoseconds: 1_000_000,
            menuCleanupNanoseconds    : 2_000_000_000
        )
        let context = try await Self.ready(profile: expiring)
        var revokedInside = false

        let outcome = try await context.seat.withContextMenu(
            openedAt   : Self.openAt,
            observation: try await observedReference(context.seat),
            turn       : context.turn
        ) { interaction in
            try? await Task.sleep(for: .milliseconds(20))
            revokedInside = interaction.isRevoked
            if case .failure(.menuContextRevoked) = await interaction.observe() {
                revokedInside = true
            }
        }

        #expect(revokedInside)
        #expect(outcome.interactionExpired)
        // The budget limits the interaction, never the cleanup: closing is the
        // kit's obligation and it has its own two seconds.
        #expect(outcome.cleanup == .verifiedClosed(.preparationCycle))
    }

    @Test("answering nothing chooses nothing, and the menu is closed anyway")
    func choosingNothingStillCloses() async throws {

        let context = try await Self.ready()

        let outcome = try await context.seat.withContextMenu(
            openedAt   : Self.openAt,
            observation: try await observedReference(context.seat),
            turn       : context.turn
        )

        #expect(outcome.insideMenu.isEmpty)
        #expect(outcome.cleanup == .verifiedClosed(.preparationCycle))
        #expect(context.sender.preparationCycles == [FakeGeometry.windowNumber])
    }

    // MARK: The teardown

    @Test("the preparation cycle is the first lever, and it is pulled on the target")
    func theCycleIsTheFirstLever() async throws {

        let context = try await Self.ready(closedBy: [.preparationCycle])

        let outcome = try await context.seat.withContextMenu(
            openedAt   : Self.openAt,
            observation: try await observedReference(context.seat),
            turn       : context.turn
        )

        #expect(outcome.cleanup == .verifiedClosed(.preparationCycle))
        // The cycle goes to the target's window and never to the menu's: what
        // the tracking loop watches is the target's own application state.
        #expect(context.sender.preparationCycles == [FakeGeometry.windowNumber])
        #expect(!context.sender.sent.contains { command, _ in
            command == .key(virtualKey: 53, text: "", modifiers: [])
        }, "no escape was needed, so none was posted")
    }

    @Test("an escape is the second net, and it is routed to the target's process")
    func escapeIsTheSecondNet() async throws {

        let context = try await Self.ready(closedBy: [.escapeKey])

        let outcome = try await context.seat.withContextMenu(
            openedAt   : Self.openAt,
            observation: try await observedReference(context.seat),
            turn       : context.turn
        )

        #expect(outcome.cleanup == .verifiedClosed(.escapeKey))
        #expect(context.sender.preparationCycles == [FakeGeometry.windowNumber])
        #expect(context.sender.sent.contains { command, _ in
            command == .key(virtualKey: 53, text: "", modifiers: [])
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

        let outcome = try await context.seat.withContextMenu(
            openedAt   : Self.openAt,
            observation: try await observedReference(context.seat),
            turn       : context.turn
        )

        #expect(outcome.cleanup == .verifiedClosed(.escapeKey))
        #expect(context.seat.state == .degraded)
    }

    @Test("a target that dismissed its own menu is said to have done so")
    func aMenuThatWentAwayOnItsOwn() async throws {

        let context = try await Self.ready()

        // The menu opens, the body looks at it and chooses nothing, and the
        // target has dropped it by the time the cleanup looks: an application
        // switch does exactly this.
        let outcome = try await context.seat.withContextMenu(
            openedAt   : Self.openAt,
            observation: try await observedReference(context.seat),
            turn       : context.turn
        ) { _ in
            context.sensing.menus = []
        }

        #expect(outcome.cleanup == .verifiedClosed(.dismissedItself))
        #expect(context.sender.preparationCycles.isEmpty, "no lever was pulled at all")
    }

    @Test("a menu nothing closes is the loudest failure the action has")
    func aMenuLeftOpenIsCritical() async throws {

        let context = try await Self.ready(closedBy: [])
        let observation = try await observedReference(context.seat)

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
            try await context.seat.withContextMenu(
                openedAt   : Self.openAt,
                observation: observation,
                turn       : context.turn
            )
        }

        // Both levers were pulled before it gave up.
        #expect(context.sender.preparationCycles == [FakeGeometry.windowNumber])
        #expect(context.sender.sent.contains { command, _ in
            command == .key(virtualKey: 53, text: "", modifiers: [])
        })

        for _ in 0 ..< 20 { await Task.yield() }
        #expect(issues.contains(.contextMenuLeftOpen))
        #expect(SeatIssue.contextMenuLeftOpen.isCritical)
    }

    @Test("the menu is closed even when the item click was refused, and the refusal survives")
    func closingWinsOverAFailedChoice() async throws {

        let context = try await Self.ready(closedBy: [.preparationCycle])
        context.sender.refusedCommand = { command in
            if case .click(_, .left, _) = command { return InputFailure.invalidLocation }
            return nil
        }

        var refusal: (any Error)?

        let outcome = try await context.seat.withContextMenu(
            openedAt   : Self.openAt,
            observation: try await observedReference(context.seat),
            turn       : context.turn
        ) { interaction in
            guard case .success(let delivery) = await interaction.observe() else { return }
            let frame = delivery.geometry.window.frame
            guard let point = InputLocation(
                screenPoint: CGPoint(x: frame.minX + 10, y: frame.minY + 10),
                observedIn : delivery.geometry
            ) else { return }
            do {
                _ = try await interaction.send(
                    .click(point, button: .left),
                    observation: delivery.reference
                )
            } catch { refusal = error }
        }

        #expect(refusal as? InputFailure == .invalidLocation)
        #expect(outcome.insideMenu.isEmpty, "nothing went out, so nothing is recorded")
        #expect(context.sender.preparationCycles == [FakeGeometry.windowNumber],
                "the cleanup ran although the choice threw")
    }
}
