import CoreGraphics
import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

@MainActor
@Suite("Routing window-level keys without a focused control")
struct OrdinaryKeyboardRoutingTests {
    @MainActor
    private final class Proof {
        enum KeyboardReading: Equatable {
            case absent
            case sameWindowControl
            case foreignControl
            case unreadable
        }

        var geometry: WindowGeometryObservation?
        var isValid = true
        var readings = 0
        var keyboardReadings = 0
        var keyboardReading: KeyboardReading = .absent

        var discovery: EndpointDiscovery {
            EndpointDiscovery(
                pointer: { _, _, _, _ in .failure(.noNodeAtPoint) },
                keyboardContext: { [self] _, chain, generation in
                    keyboardReadings += 1
                    guard let geometry else {
                        return .failure(.subtreeUnreadable(surface: chain.surface))
                    }
                    let now = DispatchTime.now().uptimeNanoseconds
                    switch keyboardReading {
                    case .absent:
                        return .failure(.subtreeUnreadable(surface: chain.surface))
                    case .unreadable:
                        return .failure(.subtreeUnreadable(surface: chain.surface))
                    case .sameWindowControl:
                        guard let endpoint = ResolvedInputEndpoint(
                            kind: .keyboardContext,
                            geometry: geometry,
                            evidence: .attestedSurfaceItself,
                            relation: .logicalSurface,
                            logicalSurface: chain.surface,
                            accessibilityProcessID: chain.surface.processID,
                            selectionGeneration: generation,
                            resolvedAtNanoseconds: now,
                            expiresAtNanoseconds: now + 500_000_000,
                            focusedNodeWindowNumber: chain.surface.windowNumber
                        ) else { return .failure(.incoherentEndpoint(windowNumber: chain.surface.windowNumber)) }
                        return .success(endpoint)
                    case .foreignControl:
                        let foreign = WindowGeometryObservation(
                            window: FakeGeometry.reference(
                                frame: geometry.window.frame,
                                processID: FakeGeometry.distinctProcessID(),
                                windowNumber: 9_011
                            ),
                            scaleFactor: geometry.scaleFactor,
                            version: geometry.version
                        )!
                        guard let endpoint = ResolvedInputEndpoint(
                            kind: .keyboardContext,
                            geometry: foreign,
                            evidence: .accessibilityNodeIdentity,
                            relation: .remoteContent,
                            logicalSurface: chain.surface,
                            accessibilityProcessID: chain.surface.processID,
                            selectionGeneration: generation,
                            resolvedAtNanoseconds: now,
                            expiresAtNanoseconds: now + 500_000_000,
                            focusedNodeWindowNumber: foreign.window.windowNumber
                        ) else { return .failure(.incoherentEndpoint(windowNumber: chain.surface.windowNumber)) }
                        return .success(endpoint)
                    }
                },
                identity: { [self] _ in geometry?.window.identity },
                focusedWindowNumber: { _ in nil },
                ordinaryKeyboardContext: { [self] _, chain, generation in
                    readings += 1
                    guard isValid, keyboardReading == .absent, let geometry else {
                        return .failure(.subtreeUnreadable(surface: chain.surface))
                    }
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard let endpoint = ResolvedInputEndpoint(
                        kind: .keyboardContext,
                        geometry: geometry,
                        evidence: .focusedWindowWithoutFocusedControl,
                        relation: .logicalSurface,
                        logicalSurface: chain.surface,
                        accessibilityProcessID: chain.surface.processID,
                        selectionGeneration: generation,
                        resolvedAtNanoseconds: now,
                        expiresAtNanoseconds: now + 500_000_000,
                        focusedNodeWindowNumber: chain.surface.windowNumber
                    ) else { return .failure(.incoherentEndpoint(windowNumber: chain.surface.windowNumber)) }
                    return .success(endpoint)
                }
            )
        }
    }

    private func context(modal: Bool = false) async throws -> (
        seat: AgentSeat, sender: FakeSender, proof: Proof, observation: SeatObservationReference
    ) {
        let sensing = FakeSensing()
        let sender = FakeSender()
        let proof = Proof()
        let reader = ControlledSurfaceReader(sensing: sensing)
        let seat = makeSeat(
            sensing: sensing, sender: sender, marker: 2_109,
            reader: reader, source: ControlledObservationSource(sensing: sensing),
            clock: ControlledContentClock(), endpoints: proof.discovery
        )
        let window = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: ChromiumPlatform()
        )
        if modal {
            reader.roles[window.id] = .dialog
            reader.modals[window.id] = .application
            seat.refreshTargetReadings()
            seat.refreshTargetReadings()
        }
        proof.geometry = sensing.windowGeometryObservation(of: window.reference)
        return (seat, sender, proof, try await observedReference(seat))
    }

    @Test("a window-level key keeps the application's recipe and rechecks the complete proof")
    func anOrdinaryWindowCanReceiveKeysWithoutAFocusedControl() async throws {
        let context = try await context()
        let turn = try await context.seat.acquire()
        let receipt = try await context.seat.send(
            .key(virtualKey: 31, text: "", modifiers: [.command]),
            observation: context.observation, turn: turn
        )
        #expect(context.sender.sent.count == 1)
        #expect(context.sender.addressed.last?.platform is ChromiumPlatform)
        #expect(context.proof.readings >= 3)
        try context.seat.confirm(receipt, .unknown)
        try context.seat.release(turn)
    }

    @Test("a tree that stops proving one window during preparation posts nothing")
    func aChangedProofAtTheFinalBoundaryPostsNothing() async throws {
        let context = try await context()
        var enteredPreparation = false
        context.sender.onSendWait = {
            enteredPreparation = true
            context.proof.isValid = false
        }
        let turn = try await context.seat.acquire()
        await #expect(throws: InputEndpointInvalidation.focusedNodeChanged) {
            try await context.seat.send(
                .key(virtualKey: 31, text: "", modifiers: [.command]),
                observation: context.observation, turn: turn
            )
        }
        #expect(enteredPreparation)
        #expect(context.sender.sent.isEmpty)
        try context.seat.release(turn)
    }

    @Test("a focused control that appears in the same attested window replaces the absence proof")
    func aSameWindowControlAtTheFinalBoundaryPosts() async throws {
        let context = try await context()
        context.sender.onSendWait = {
            context.proof.keyboardReading = .sameWindowControl
        }

        let turn = try await context.seat.acquire()
        let receipt = try await context.seat.send(
            .key(virtualKey: 31, text: "", modifiers: [.command]),
            observation: context.observation, turn: turn
        )

        #expect(context.sender.sent.count == 1)
        #expect(context.proof.keyboardReadings >= 3,
                "the normal focus route must be read again at the final boundary")
        try context.seat.confirm(receipt, .unknown)
        try context.seat.release(turn)
    }

    @Test(arguments: [
        Proof.KeyboardReading.foreignControl,
        .unreadable,
    ])
    private func aForeignOrUnreadableControlAtTheFinalBoundaryPostsNothing(
        reading: Proof.KeyboardReading
    ) async throws {
        let context = try await context()
        context.sender.onSendWait = {
            context.proof.keyboardReading = reading
        }

        let turn = try await context.seat.acquire()
        await #expect(throws: InputEndpointInvalidation.focusedNodeChanged) {
            try await context.seat.send(
                .key(virtualKey: 31, text: "", modifiers: [.command]),
                observation: context.observation, turn: turn
            )
        }
        #expect(context.sender.sent.isEmpty)
        try context.seat.release(turn)
    }

    @Test("an application-modal panel never asks for an ordinary window proof")
    func aModalPanelDoesNotUseTheOrdinaryRoute() async throws {
        let context = try await context(modal: true)
        let turn = try await context.seat.acquire()
        await #expect(throws: InputEndpointRefusal.subtreeUnreadable(surface: context.observation.surface)) {
            try await context.seat.send(
                .key(virtualKey: 53, text: ""), observation: context.observation, turn: turn
            )
        }
        #expect(context.proof.readings == 0)
        #expect(context.sender.sent.isEmpty)
        try context.seat.release(turn)
    }
}
