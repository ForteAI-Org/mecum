//
//  UXPModalRoutingTests.swift
//  AgentSeatKit
//

import CoreGraphics
import Dispatch
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// Stale global AX focus cannot address a blocked document. The exceptional
/// UXP route needs a complete modal proof, prepared keys and a repeated proof
/// after preparation. These fixture readings establish no native effect.
@MainActor
@Suite("UXP modal keys with stale document focus")
struct UXPModalRoutingTests {
    private static let key = InputCommand.key(virtualKey: 53, text: "")

    @Test("a focused modal never inherits Photoshop's document click preparation")
    func modalDropsDocumentRecipe() throws {
        let point = InputLocation(screenPoint: .zero, windowPointFromTop: .zero)
        let family = UXPPlatform().preparingLeftClicks.preparingKeys
        let document = try #require(SurfaceInputClassification.drivenApplication.platform(
            for: .click(point), ofDrivenApplication: family
        ))
        let modal = try #require(SurfaceInputClassification.drivenApplication.platform(
            for: .click(point), ofDrivenApplication: family, isModalSurface: true
        ))
        #expect(document.preparation(for: .click(point)) == .internalAppKitState)
        #expect(modal.preparation(for: .click(point)) == .none)
        #expect(modal.preparation(for: Self.key) == .none)
    }

    @MainActor
    private final class Readings {
        var blockedNumber = 0
        var modal: WindowGeometryObservation?
        var identities: [Int: WindowIdentity] = [:]
        var complete = true
        var absentFocus = false
        var proxyProof = false
        var containedBlockedEndpoint = false
        var containedBlockedPointer = false
        var ownModalPointer = false

        var discovery: EndpointDiscovery {
            EndpointDiscovery(
                pointer: { [self] _, _, chain, generation in
                    if ownModalPointer, let modal {
                        let now = DispatchTime.now().uptimeNanoseconds
                        guard let endpoint = ResolvedInputEndpoint(
                            kind: .pointer, geometry: modal, evidence: .accessibilityNodeIdentity,
                            relation: .logicalSurface, logicalSurface: chain.surface,
                            accessibilityProcessID: chain.surface.processID, selectionGeneration: generation,
                            resolvedAtNanoseconds: now, expiresAtNanoseconds: now + 500_000_000
                        ) else { return .failure(.incoherentEndpoint(windowNumber: chain.surface.windowNumber)) }
                        return .success(endpoint)
                    }
                    guard containedBlockedPointer, let identity = identities[blockedNumber] else {
                        return .failure(.noNodeAtPoint)
                    }
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard let geometry = WindowGeometryObservation(
                        window: WindowReference(identity: identity, frame: CGRect(
                            x: chain.surfaceFrame.minX + 10, y: chain.surfaceFrame.minY + 10,
                            width: 100, height: 40)), scaleFactor: 2,
                        version: GeometryObservationVersion(observerGeneration: 1, sequence: 1)
                    ) else { return .failure(.geometryUnavailable(windowNumber: blockedNumber)) }
                    guard let endpoint = ResolvedInputEndpoint(
                        kind: .pointer, geometry: geometry, evidence: .accessibilityNodeIdentity,
                        relation: .remoteContent, logicalSurface: chain.surface,
                        accessibilityProcessID: chain.surface.processID, selectionGeneration: generation,
                        resolvedAtNanoseconds: now, expiresAtNanoseconds: now + 500_000_000
                    ) else { return .failure(.incoherentEndpoint(windowNumber: blockedNumber)) }
                    return .success(endpoint)
                },
                keyboardContext: { [self] _, chain, generation in
                    if containedBlockedEndpoint, let identity = identities[blockedNumber] {
                        let now = DispatchTime.now().uptimeNanoseconds
                        guard let geometry = WindowGeometryObservation(
                            window: WindowReference(identity: identity, frame: CGRect(
                                x: chain.surfaceFrame.minX + 10, y: chain.surfaceFrame.minY + 10,
                                width: 100, height: 40)), scaleFactor: 2,
                            version: GeometryObservationVersion(observerGeneration: 1, sequence: 1)
                        ) else { return .failure(.geometryUnavailable(windowNumber: blockedNumber)) }
                        guard let endpoint = ResolvedInputEndpoint(
                            kind: .keyboardContext, geometry: geometry, evidence: .accessibilityNodeIdentity,
                            relation: .remoteContent, logicalSurface: chain.surface,
                            accessibilityProcessID: chain.surface.processID, selectionGeneration: generation,
                            resolvedAtNanoseconds: now, expiresAtNanoseconds: now + 500_000_000,
                            focusedNodeWindowNumber: blockedNumber
                        ) else { return .failure(.incoherentEndpoint(windowNumber: blockedNumber)) }
                        return .success(endpoint)
                    }
                    return absentFocus ? .failure(.subtreeUnreadable(surface: chain.surface))
                        : .failure(.notContainedInSurface(windowNumber: blockedNumber))
                },
                identity: { [self] in identities[$0] },
                focusedWindowNumber: { [self] _ in absentFocus ? nil : blockedNumber },
                mainWindowUnderFocusProxyKeyboardContext: { [self] _, chain, generation in
                    guard proxyProof, complete, let modal else {
                        return .failure(.subtreeUnreadable(surface: chain.surface))
                    }
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard let endpoint = ResolvedInputEndpoint(
                        kind: .keyboardContext, geometry: modal, evidence: .mainWindowUnderFocusProxy,
                        relation: .logicalSurface, logicalSurface: chain.surface,
                        accessibilityProcessID: chain.surface.processID, selectionGeneration: generation,
                        resolvedAtNanoseconds: now, expiresAtNanoseconds: now + 500_000_000
                    ) else { return .failure(.incoherentEndpoint(windowNumber: chain.surface.windowNumber)) }
                    return .success(endpoint)
                },
                modalSurfaceKeyboardContext: { [self] _, chain, generation in
                    guard complete, let modal else { return .failure(.subtreeUnreadable(surface: chain.surface)) }
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard let endpoint = ResolvedInputEndpoint(
                        kind: .keyboardContext, geometry: modal, evidence: .unfocusedModalSurface,
                        relation: .logicalSurface, logicalSurface: chain.surface,
                        accessibilityProcessID: chain.surface.processID,
                        selectionGeneration: generation,
                        resolvedAtNanoseconds: now, expiresAtNanoseconds: now + 500_000_000
                    ) else { return .failure(.incoherentEndpoint(windowNumber: chain.surface.windowNumber)) }
                    return .success(endpoint)
                }
            )
        }
    }

    private struct Scenario {
        let seat: AgentSeat
        let sender: FakeSender
        let readings: Readings
        let document: AdoptedWindow
        let modal: AdoptedWindow
    }

    private func scenario(
        uxp             : Bool = true,
        applicationModal: Bool = true,
        nonmodalDialog  : Bool = false,
        role            : SurfaceRole = .dialog,
        calibratedDocument: Bool = false
    ) async throws -> Scenario {
        let sensing = FakeSensing()
        let sender = FakeSender()
        let reader = ControlledSurfaceReader(sensing: sensing)
        let readings = Readings()
        let seat = makeSeat(sensing: sensing, sender: sender, marker: 1_919, reader: reader,
                            endpoints: readings.discovery)
        let platform: any InputPlatform = uxp
            ? (calibratedDocument ? UXPPlatform().preparingLeftClicks.preparingKeys : UXPPlatform())
            : ChromiumPlatform()
        let document = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame), platform: platform
        )
        let inbound = FakeGeometry.reference(
            frame: FakeGeometry.adoptedWindow.frame.offsetBy(dx: 60, dy: 60), windowNumber: 888
        )
        sensing.additionalWindows[888] = inbound
        let modal = try await seat.adopt(inbound, platform: platform)
        sensing.additionalWindows[888] = modal.reference
        reader.roles[888] = role
        if !nonmodalDialog {
            reader.modals[888] = applicationModal ? .application : .window(try #require(document.reference.identity))
        }
        readings.blockedNumber = document.id
        readings.identities[document.id] = document.reference.identity
        readings.identities[888] = modal.reference.identity
        readings.modal = WindowGeometryObservation(
            window: modal.reference, scaleFactor: 2,
            version: GeometryObservationVersion(observerGeneration: 1, sequence: 1)
        )
        seat.refreshTargetReadings()
        seat.refreshTargetReadings()
        if nonmodalDialog { try await seat.switchTarget(to: modal) }
        return Scenario(seat: seat, sender: sender, readings: readings, document: document, modal: modal)
    }

    @Test("only the attested modal is made key while global focus still names the document")
    func primesOnlyTheModal() async throws {
        let sample = try await scenario()
        let observation = try await observedReference(sample.seat)
        #expect(observation.surface.windowNumber == sample.modal.id)
        let turn = try await sample.seat.acquire()
        let receipt = try await sample.seat.send(Self.key, observation: observation, turn: turn)
        let addressed = try #require(sample.sender.addressed.last)
        #expect(addressed.window.identity == sample.modal.reference.identity)
        #expect(addressed.window.windowNumber != sample.document.id)
        #expect(addressed.platform.preparation(for: Self.key) == .none)
        #expect(addressed.platform.keyWindowPriming(for: Self.key)?.host.identity == sample.modal.reference.identity)
        #expect(addressed.platform.keyWindowPriming(for: Self.key)?.settle == .milliseconds(300))
        try sample.seat.confirm(receipt, .unknown)
        try sample.seat.release(turn)
    }

    @Test("the application document recipe is removed at the actual modal send boundary", arguments: [true, false])
    func modalCommandDropsCalibration(_ overrideRecipe: Bool) async throws {
        let sample = try await scenario(calibratedDocument: true)
        sample.readings.ownModalPointer = true
        let observation = try await observedReference(sample.seat)
        let turn = try await sample.seat.acquire()
        let point = InputLocation(
            screenPoint: CGPoint(x: sample.modal.reference.frame.midX, y: sample.modal.reference.frame.midY),
            windowPointFromTop: CGPoint(x: sample.modal.reference.frame.width / 2,
                                        y: sample.modal.reference.frame.height / 2)
        )
        if overrideRecipe {
            await #expect(throws: SessionFailure.surfaceFamilyUnclassified(windowNumber: sample.modal.id)) {
                try await sample.seat.send(.click(point), observation: observation, turn: turn,
                                           platform: UXPPlatform().preparingLeftClicks)
            }
            #expect(sample.sender.sent.isEmpty)
        } else {
            let receipt = try await sample.seat.send(.click(point), observation: observation, turn: turn)
            let addressed = try #require(sample.sender.addressed.last)
            #expect(addressed.window.identity == sample.modal.reference.identity)
            #expect(addressed.platform.preparation(for: .click(point)) == .none)
            try sample.seat.confirm(receipt, .unknown)
        }
        try sample.seat.release(turn)
    }

    @Test("an incomplete modal, another family, a hosted sheet or an unknown focused window refuses", arguments: 0..<4)
    func requiresTheNarrowModalProof(_ refusal: Int) async throws {
        let sample = try await scenario(uxp: refusal != 1, applicationModal: refusal != 2)
        if refusal == 0 { sample.readings.complete = false }
        if refusal == 3 { sample.readings.blockedNumber = 999 }
        let observation = try await observedReference(sample.seat)
        let turn = try await sample.seat.acquire()
        await #expect(throws: InputEndpointRefusal.notContainedInSurface(windowNumber: sample.readings.blockedNumber)) {
            try await sample.seat.send(Self.key, observation: observation, turn: turn)
        }
        #expect(sample.sender.sent.isEmpty)
        try sample.seat.release(turn)
    }

    @Test("a contained blocked document never becomes the modal recipient", arguments: [true, false])
    func containedBlockedDocument(_ complete: Bool) async throws {
        let sample = try await scenario()
        sample.readings.containedBlockedEndpoint = true
        sample.readings.complete = complete
        let observation = try await observedReference(sample.seat)
        let turn = try await sample.seat.acquire()
        if complete {
            let receipt = try await sample.seat.send(Self.key, observation: observation, turn: turn)
            let addressed = try #require(sample.sender.addressed.last)
            #expect(addressed.window.identity == sample.modal.reference.identity)
            #expect(addressed.platform.keyWindowPriming(for: Self.key)?.host.identity == sample.modal.reference.identity)
            try sample.seat.confirm(receipt, .unknown)
        } else {
            await #expect(throws: InputEndpointRefusal.recipientModallyBlocked(windowNumber: sample.document.id)) {
                try await sample.seat.send(Self.key, observation: observation, turn: turn)
            }
            #expect(sample.sender.sent.isEmpty)
        }
        try sample.seat.release(turn)
    }

    @Test("a contained blocked pointer recipient refuses for every application family", arguments: [true, false])
    func containedBlockedPointer(_ uxp: Bool) async throws {
        let sample = try await scenario(uxp: uxp)
        sample.readings.containedBlockedPointer = true
        let observation = try await observedReference(sample.seat)
        let geometry = try #require(sample.readings.modal)
        let point = try #require(InputLocation(
            screenPoint: CGPoint(x: geometry.window.frame.minX + 20, y: geometry.window.frame.minY + 20),
            observedIn: geometry
        ))
        let turn = try await sample.seat.acquire()
        await #expect(throws: InputEndpointRefusal.recipientModallyBlocked(windowNumber: sample.document.id)) {
            try await sample.seat.send(.click(point), observation: observation, turn: turn)
        }
        #expect(sample.sender.sent.isEmpty)
        try sample.seat.release(turn)
    }

    @Test("a caller cannot omit priming, activate the modal, or prime the blocked document", arguments: 0..<3)
    func incompatibleOverrideRefuses(_ variant: Int) async throws {
        let sample = try await scenario()
        let observation = try await observedReference(sample.seat)
        let turn = try await sample.seat.acquire()
        let family = UXPPlatform()
        let override = variant == 0 ? family : variant == 1 ? family.preparingKeys
            : family.primingKeys(in: sample.document.reference)
        await #expect(throws: SessionFailure.surfaceFamilyUnclassified(windowNumber: sample.modal.id)) {
            try await sample.seat.send(Self.key, observation: observation, turn: turn, platform: override)
        }
        #expect(sample.sender.sent.isEmpty)
        try sample.seat.release(turn)
    }

    @Test("a modal subtree changed during priming prevents the first post")
    func changedContentRefusesBeforePosting() async throws {
        let sample = try await scenario()
        let observation = try await observedReference(sample.seat)
        let turn = try await sample.seat.acquire()
        sample.sender.onSendWait = { sample.readings.complete = false }
        await #expect(throws: InputEndpointInvalidation.relationNoLongerValid) {
            try await sample.seat.send(Self.key, observation: observation, turn: turn)
        }
        #expect(sample.sender.sent.isEmpty)
        try sample.seat.release(turn)
    }

    @Test("absent global focus still requires the complete own-window modal subtree", arguments: [true, false])
    func absentFocusRequiresCompleteModal(_ complete: Bool) async throws {
        let sample = try await scenario()
        sample.readings.absentFocus = true
        sample.readings.complete = complete
        let observation = try await observedReference(sample.seat)
        let turn = try await sample.seat.acquire()
        if complete {
            let receipt = try await sample.seat.send(Self.key, observation: observation, turn: turn)
            let addressed = try #require(sample.sender.addressed.last)
            #expect(addressed.platform.preparation(for: Self.key) == .none)
            #expect(addressed.platform.keyWindowPriming(for: Self.key)?.host.identity == sample.modal.reference.identity)
            try sample.seat.confirm(receipt, .unknown)
        } else {
            await #expect(throws: InputEndpointRefusal.subtreeUnreadable(surface: try #require(sample.modal.reference.identity))) {
                try await sample.seat.send(Self.key, observation: observation, turn: turn)
            }
            #expect(sample.sender.sent.isEmpty)
        }
        try sample.seat.release(turn)
    }

    @Test("a selected own-window UXP dialog may be made key when AX declares it nonmodal", arguments: [true, false])
    func selectedNonmodalDialogRequiresRole(_ isDialog: Bool) async throws {
        let sample = try await scenario(nonmodalDialog: true, role: isDialog ? .dialog : .document)
        sample.readings.absentFocus = true
        let observation = try await observedReference(sample.seat)
        #expect(observation.surface.windowNumber == sample.modal.id)
        let turn = try await sample.seat.acquire()
        if isDialog {
            let receipt = try await sample.seat.send(Self.key, observation: observation, turn: turn)
            let addressed = try #require(sample.sender.addressed.last)
            #expect(addressed.platform.preparation(for: Self.key) == .none)
            #expect(addressed.platform.keyWindowPriming(for: Self.key)?.host.identity == sample.modal.reference.identity)
            try sample.seat.confirm(receipt, .unknown)
        } else {
            await #expect(throws: InputEndpointRefusal.subtreeUnreadable(surface: try #require(sample.modal.reference.identity))) {
                try await sample.seat.send(Self.key, observation: observation, turn: turn)
            }
            #expect(sample.sender.sent.isEmpty)
        }
        try sample.seat.release(turn)
    }

    @Test("only a selected UXP document may borrow the inert-proxy main-window proof", arguments: 0..<3)
    func mainWindowProofRequiresDocument(_ variant: Int) async throws {
        let sample = try await scenario(uxp: variant != 1, nonmodalDialog: true,
                                        role: variant == 2 ? .dialog : .document)
        sample.readings.absentFocus = true
        sample.readings.proxyProof = true
        let observation = try await observedReference(sample.seat)
        let turn = try await sample.seat.acquire()
        if variant == 0 {
            let receipt = try await sample.seat.send(Self.key, observation: observation, turn: turn)
            let addressed = try #require(sample.sender.addressed.last)
            #expect(addressed.window.identity == sample.modal.reference.identity)
            #expect(addressed.platform.preparation(for: Self.key) == .none)
            #expect(addressed.platform.keyWindowPriming(for: Self.key)?.host.identity == sample.modal.reference.identity)
            try sample.seat.confirm(receipt, .unknown)
        } else if variant == 1 {
            await #expect(throws: InputEndpointRefusal.subtreeUnreadable(surface: try #require(sample.modal.reference.identity))) {
                try await sample.seat.send(Self.key, observation: observation, turn: turn)
            }
            #expect(sample.sender.sent.isEmpty)
        } else {
            // An explicitly selected dialog keeps its separate own-dialog proof.
            let receipt = try await sample.seat.send(Self.key, observation: observation, turn: turn)
            #expect(sample.sender.addressed.last?.platform.keyWindowPriming(for: Self.key)?.host.identity == sample.modal.reference.identity)
            try sample.seat.confirm(receipt, .unknown)
        }
        try sample.seat.release(turn)
    }

    @Test("a changed main-window proof prevents the first document post")
    func changedMainWindowProofRefuses() async throws {
        let sample = try await scenario(nonmodalDialog: true, role: .document)
        sample.readings.absentFocus = true
        sample.readings.proxyProof = true
        let observation = try await observedReference(sample.seat)
        let turn = try await sample.seat.acquire()
        sample.sender.onSendWait = { sample.readings.complete = false }
        await #expect(throws: InputEndpointInvalidation.relationNoLongerValid) {
            try await sample.seat.send(Self.key, observation: observation, turn: turn)
        }
        #expect(sample.sender.sent.isEmpty)
        try sample.seat.release(turn)
    }

    @Test("document proxy proof refuses an override without exact key-window priming", arguments: 0..<3)
    func mainWindowOverrideMustPrimeExactDocument(_ variant: Int) async throws {
        let sample = try await scenario(nonmodalDialog: true, role: .document)
        sample.readings.absentFocus = true
        sample.readings.proxyProof = true
        let observation = try await observedReference(sample.seat)
        let turn = try await sample.seat.acquire()
        let family = UXPPlatform()
        let override = variant == 0 ? family : variant == 1 ? family.preparingKeys
            : family.primingKeys(in: sample.document.reference)
        await #expect(throws: SessionFailure.surfaceFamilyUnclassified(windowNumber: sample.modal.id)) {
            try await sample.seat.send(Self.key, observation: observation, turn: turn, platform: override)
        }
        #expect(sample.sender.sent.isEmpty)
        try sample.seat.release(turn)
    }

}
