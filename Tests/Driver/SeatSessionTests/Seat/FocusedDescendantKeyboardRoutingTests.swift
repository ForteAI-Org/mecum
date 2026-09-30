import CoreGraphics
import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

@MainActor
@Suite("Routing keys from focus declared inside a modal surface")
struct FocusedDescendantKeyboardRoutingTests {
    typealias Fixture = GestureEndpointRoutingTests

    private func endpoint(
        _ content: WindowGeometryObservation,
        surface: WindowIdentity,
        generation: UInt64,
        evidence: InputEndpointEvidence = .focusedSurfaceDescendant,
        lifetimeNanoseconds: UInt64 = 500_000_000
    ) throws -> ResolvedInputEndpoint {
        let now = DispatchTime.now().uptimeNanoseconds
        return try #require(ResolvedInputEndpoint(
            kind: .keyboardContext,
            geometry: content,
            evidence: evidence,
            relation: .remoteContent,
            logicalSurface: surface,
            accessibilityProcessID: surface.processID,
            selectionGeneration: generation,
            resolvedAtNanoseconds: now,
            expiresAtNanoseconds: now + lifetimeNanoseconds,
            focusedNodeWindowNumber: content.window.windowNumber
        ))
    }

    private func context() async throws -> (
        panel: Fixture.Panel, observation: SeatObservationReference,
        content: WindowGeometryObservation
    ) {
        let panel = try await Fixture.panel()
        let observation = try await observedReference(panel.seat)
        let surface = try #require(panel.sheet.reference.identity)
        let content = try Fixture.remoteContent(of: panel)
        panel.discovery.keyboardAnswer = .failure(.subtreeUnreadable(surface: surface))
        panel.discovery.descendantKeyboardAnswer = .success(try endpoint(
            content, surface: surface, generation: observation.selectionGeneration
        ))
        panel.discovery.identities[content.window.windowNumber] = content.window.identity
        return (panel, observation, content)
    }

    @Test("Escape reaches the qualified remote content when focus is declared by its descendants")
    func remoteContentReceivesTheKey() async throws {
        let (panel, observation, content) = try await context()
        let turn = try await panel.seat.acquire()
        let receipt = try await panel.seat.send(
            KeyboardEndpointRoutingTests.escapeKey, observation: observation, turn: turn
        )
        let addressed = try #require(panel.sender.addressed.last)
        #expect(addressed.window.identity == content.window.identity)
        #expect(addressed.window.processID != panel.host.reference.processID)
        #expect(addressed.platform is RemoteKeyboardPlatform)
        #expect(panel.sender.sent.count == 1)
        #expect(panel.discovery.points.isEmpty)
        try panel.seat.confirm(receipt, .unknown)
        try panel.seat.release(turn)
    }

    @Test("focus becoming unreadable during preparation posts nothing")
    func unreadableFocusAtTheFinalBoundaryRefuses() async throws {
        let (panel, observation, _) = try await context()
        let surface = try #require(panel.sheet.reference.identity)
        panel.sender.onSendWait = {
            panel.discovery.descendantKeyboardAnswer = .failure(
                .subtreeUnreadable(surface: surface)
            )
        }
        let turn = try await panel.seat.acquire()
        await #expect(throws: InputEndpointInvalidation.focusedNodeChanged) {
            try await panel.seat.send(
                KeyboardEndpointRoutingTests.escapeKey, observation: observation, turn: turn
            )
        }
        #expect(panel.sender.sent.isEmpty)
        try panel.seat.release(turn)
    }

    @Test("focus moving to a different remote window during preparation posts nothing")
    func differentRecipientAtTheFinalBoundaryRefuses() async throws {
        let (panel, observation, content) = try await context()
        let surface = try #require(panel.sheet.reference.identity)
        let other = try #require(WindowGeometryObservation(
            window: FakeGeometry.reference(
                frame: content.window.frame,
                processID: content.window.processID,
                windowNumber: Fixture.remoteWindowNumber + 1
            ),
            scaleFactor: content.scaleFactor,
            version: content.version
        ))
        let replacement = try endpoint(
            other, surface: surface, generation: observation.selectionGeneration
        )
        panel.discovery.identities[other.window.windowNumber] = other.window.identity
        panel.sender.onSendWait = {
            panel.discovery.descendantKeyboardAnswer = .success(replacement)
        }
        let turn = try await panel.seat.acquire()
        await #expect(throws: InputEndpointInvalidation.focusedNodeChanged) {
            try await panel.seat.send(
                KeyboardEndpointRoutingTests.escapeKey, observation: observation, turn: turn
            )
        }
        #expect(panel.sender.sent.isEmpty)
        try panel.seat.release(turn)
    }

    @Test("a direct focused node in the same remote window can replace the descendant proof")
    func directFocusInTheSameRecipientCanTakeOver() async throws {
        let (panel, observation, content) = try await context()
        let sheet = try #require(panel.sheet.reference.identity)
        let direct = try endpoint(
            content, surface: sheet, generation: observation.selectionGeneration,
            evidence: .accessibilityNodeIdentity
        )
        panel.sender.onSendWait = {
            panel.discovery.keyboardAnswer = .success(direct)
            panel.discovery.descendantKeyboardAnswer = .failure(
                .subtreeUnreadable(surface: observation.surface)
            )
        }
        let turn = try await panel.seat.acquire()
        let receipt = try await panel.seat.send(
            KeyboardEndpointRoutingTests.escapeKey, observation: observation, turn: turn
        )
        #expect(panel.sender.sent.count == 1)
        #expect(panel.sender.addressed.last?.window.identity == content.window.identity)
        try panel.seat.confirm(receipt, .unknown)
        try panel.seat.release(turn)
    }

    @Test("an ordinary window never consults the modal descendant route")
    func ordinaryWindowKeepsItsOwnProof() async throws {
        let sensing = FakeSensing()
        let sender = FakeSender()
        let discovery = Fixture.Discovery()
        let seat = makeSeat(
            sensing: sensing, sender: sender, marker: 3_811,
            reader: ControlledSurfaceReader(sensing: sensing),
            source: ControlledObservationSource(sensing: sensing),
            clock: ControlledContentClock(), endpoints: discovery.discovery
        )
        let window = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: ChromiumPlatform()
        )
        let identity = try #require(window.reference.identity)
        discovery.keyboardAnswer = .failure(.subtreeUnreadable(surface: identity))
        let content = try #require(WindowGeometryObservation(
            window: FakeGeometry.reference(
                frame: window.reference.frame.insetBy(dx: 20, dy: 20),
                processID: FakeGeometry.distinctProcessID(),
                windowNumber: Fixture.remoteWindowNumber
            ),
            scaleFactor: 2,
            version: GeometryObservationVersion(observerGeneration: 3, sequence: 9)
        ))
        discovery.remoteContentKeyboardAnswer = .success(try endpoint(
            content, surface: identity, generation: 0, evidence: .remoteContentOfSurface
        ))
        let observation = try await observedReference(seat)
        let turn = try await seat.acquire()
        await #expect(throws: InputEndpointRefusal.subtreeUnreadable(surface: identity)) {
            try await seat.send(
                KeyboardEndpointRoutingTests.escapeKey, observation: observation, turn: turn
            )
        }
        #expect(discovery.descendantKeyboardResolutions == 0)
        #expect(discovery.remoteContentKeyboardResolutions == 0)
        #expect(sender.sent.isEmpty)
        try seat.release(turn)
    }

    // MARK: A modal with no focused control inside it

    /// A modal whose surface names one remote content window, with the keyboard
    /// discovery answering `keyboard` and the remote route answering `remote`.
    private func focuslessContext(
        keyboard: (Fixture.Panel, WindowIdentity, UInt64) throws
            -> Result<ResolvedInputEndpoint, InputEndpointRefusal>,
        remoteAnswers: Bool = true
    ) async throws -> (
        panel: Fixture.Panel, observation: SeatObservationReference,
        content: WindowGeometryObservation
    ) {
        let panel = try await Fixture.panel()
        let observation = try await observedReference(panel.seat)
        let surface = try #require(panel.sheet.reference.identity)
        let content = try Fixture.remoteContent(of: panel)
        panel.discovery.keyboardAnswer = try keyboard(panel, surface, observation.selectionGeneration)
        // A parallel run takes longer than a real endpoint lives.
        panel.discovery.remoteContentKeyboardAnswer = remoteAnswers
            ? .success(try endpoint(
                content, surface: surface, generation: observation.selectionGeneration,
                evidence: .remoteContentOfSurface, lifetimeNanoseconds: 60_000_000_000
            ))
            : .failure(.subtreeUnreadable(surface: surface))
        panel.discovery.identities[content.window.windowNumber] = content.window.identity
        panel.discovery.identities[Fixture.sheetWindowNumber] = surface
        panel.discovery.focusedWindowNumber = Fixture.sheetWindowNumber
        return (panel, observation, content)
    }

    /// The keyboard discovery's answer for a focus on the surface's own window
    /// node: the surface itself.
    private static func theSurfaceItself(
        _ panel: Fixture.Panel, _ surface: WindowIdentity, _ generation: UInt64
    ) throws -> Result<ResolvedInputEndpoint, InputEndpointRefusal> {
        .success(try Fixture.endpoint(
            try #require(WindowGeometryObservation(
                window: panel.sheet.reference,
                scaleFactor: 2,
                version: GeometryObservationVersion(observerGeneration: 4, sequence: 11)
            )),
            kind: .keyboardContext,
            relation: .logicalSurface,
            logicalSurface: surface,
            generation: generation,
            hostProcessID: panel.host.reference.processID,
            focusedNodeWindowNumber: Fixture.sheetWindowNumber,
            lifetimeNanoseconds: 60_000_000_000
        ))
    }

    @Test("keys for a modal focused on its own window keep going to the modal itself")
    func aModalFocusedOnItselfKeepsItsOwnRoute() async throws {
        // Escape to the panel window closed it; `/` to the service did nothing (30/09/2026).
        let (panel, observation, _) = try await focuslessContext(keyboard: Self.theSurfaceItself)
        let surface = try #require(panel.sheet.reference.identity)
        let turn = try await panel.seat.acquire()
        let receipt = try await panel.seat.send(
            KeyboardEndpointRoutingTests.escapeKey, observation: observation, turn: turn
        )
        #expect(panel.sender.addressed.last?.window.identity == surface)
        #expect(!(panel.sender.addressed.last?.platform is RemoteKeyboardPlatform))
        #expect(panel.discovery.remoteContentKeyboardResolutions == 0, "the remote route was never asked")
        #expect(panel.discovery.focusedContentKeyboardResolutions > 0, "no focused field was found in the content")
        #expect(panel.sender.sent.count == 1)
        try panel.seat.confirm(receipt, .unknown)
        try panel.seat.release(turn)
    }

    @Test("keys for a modal focused on its own window with a field clicked go to that field's window, host primed")
    func aClickedFieldInTheContentTakesTheKeys() async throws {
        // After a click on the Save panel's name field, `/` to the service opened Go to Folder (30/09/2026).
        let (panel, observation, content) = try await focuslessContext(keyboard: Self.theSurfaceItself)
        let surface = try #require(panel.sheet.reference.identity)
        panel.discovery.focusedContentKeyboardAnswer = .success(try endpoint(
            content, surface: surface, generation: observation.selectionGeneration,
            evidence: .focusedSurfaceDescendant, lifetimeNanoseconds: 60_000_000_000
        ))
        let turn = try await panel.seat.acquire()
        let receipt = try await panel.seat.send(
            KeyboardEndpointRoutingTests.escapeKey, observation: observation, turn: turn
        )
        let addressed = try #require(panel.sender.addressed.last)
        #expect(addressed.window.identity == content.window.identity)
        #expect(addressed.platform is RemoteKeyboardPlatform)
        #expect(addressed.platform.keyWindowPriming(for: KeyboardEndpointRoutingTests.escapeKey)?
            .host.windowNumber == panel.sheet.reference.windowNumber)
        // Sent once means both boundary readings reached the same recipient.
        #expect(panel.sender.sent.count == 1)
        try panel.seat.confirm(receipt, .unknown)
        try panel.seat.release(turn)
    }

    @Test("a focused descendant in a window of the modal's own process keeps the modal as recipient")
    func aFocusedDescendantOfTheSameProcessKeepsTheModal() async throws {
        let (panel, observation, content) = try await focuslessContext(keyboard: Self.theSurfaceItself)
        let surface = try #require(panel.sheet.reference.identity)
        let accessory = try #require(WindowGeometryObservation(
            window: FakeGeometry.reference(
                frame: content.window.frame,
                processID: surface.processID,
                windowNumber: Fixture.remoteWindowNumber + 2
            ),
            scaleFactor: content.scaleFactor,
            version: content.version
        ))
        panel.discovery.focusedContentKeyboardAnswer = .success(try endpoint(
            accessory, surface: surface, generation: observation.selectionGeneration,
            evidence: .focusedSurfaceDescendant, lifetimeNanoseconds: 60_000_000_000
        ))
        let turn = try await panel.seat.acquire()
        let receipt = try await panel.seat.send(
            KeyboardEndpointRoutingTests.escapeKey, observation: observation, turn: turn
        )
        #expect(panel.sender.addressed.last?.window.identity == surface)
        #expect(!(panel.sender.addressed.last?.platform is RemoteKeyboardPlatform))
        try panel.seat.confirm(receipt, .unknown)
        try panel.seat.release(turn)
    }

    @Test("keys for a modal whose focus cannot be read go to its remote content, host primed")
    func aModalWithAnUnreadableFocusTypesIntoItsRemoteContent() async throws {
        let (panel, observation, content) = try await focuslessContext { _, surface, _ in
            .failure(.subtreeUnreadable(surface: surface))
        }
        let turn = try await panel.seat.acquire()
        let receipt = try await panel.seat.send(
            KeyboardEndpointRoutingTests.escapeKey, observation: observation, turn: turn
        )
        let addressed = try #require(panel.sender.addressed.last)
        #expect(addressed.window.identity == content.window.identity)
        #expect(addressed.platform is RemoteKeyboardPlatform)
        // The modal the remote content is drawn in is the window primed first.
        #expect(addressed.platform.keyWindowPriming(for: KeyboardEndpointRoutingTests.escapeKey)?
            .host.windowNumber == panel.sheet.reference.windowNumber)
        // Sent once means both boundary readings reached the same recipient.
        #expect(panel.sender.sent.count == 1)
        try panel.seat.confirm(receipt, .unknown)
        try panel.seat.release(turn)
    }

    @Test("an unreadable focus still refuses when the remote window is unqualified or not the only one")
    func anUnreadableFocusWithoutOneQualifiedRemoteWindowRefuses() async throws {
        // One remote window of an unqualified process, then no single remote window.
        for (remoteAnswers, qualified) in [(true, false), (false, true)] {
            let (panel, observation, _) = try await focuslessContext(
                keyboard: { _, surface, _ in .failure(.subtreeUnreadable(surface: surface)) },
                remoteAnswers: remoteAnswers
            )
            panel.discovery.qualifiesRemotePanelService = qualified
            let surface = try #require(panel.sheet.reference.identity)
            let turn = try await panel.seat.acquire()
            await #expect(throws: InputEndpointRefusal.subtreeUnreadable(surface: surface)) {
                try await panel.seat.send(
                    KeyboardEndpointRoutingTests.escapeKey, observation: observation, turn: turn
                )
            }
            #expect(panel.sender.sent.isEmpty)
            try panel.seat.release(turn)
        }
    }
}
