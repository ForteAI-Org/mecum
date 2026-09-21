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
        evidence: InputEndpointEvidence = .focusedSurfaceDescendant
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
            expiresAtNanoseconds: now + 500_000_000,
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
        let observation = try await observedReference(seat)
        let turn = try await seat.acquire()
        await #expect(throws: InputEndpointRefusal.subtreeUnreadable(surface: identity)) {
            try await seat.send(
                KeyboardEndpointRoutingTests.escapeKey, observation: observation, turn: turn
            )
        }
        #expect(discovery.descendantKeyboardResolutions == 0)
        #expect(sender.sent.isEmpty)
        try seat.release(turn)
    }
}
