//
//  WindowlessContentRoutingTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/10/2026.
//

import CoreGraphics
import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// Where a click or a key on an ordinary window's content with no Window ID,
/// such as a web page, goes when discovery refused an unreadable subtree or
/// inferred an auxiliary keyboard window instead of the control's own parent. The decision is the resolver's, proven in
/// `DialogEndpointResolverTests`; on trial here is only when the seat asks for
/// it and what reaches the driver.
@MainActor
@Suite("Routing input to a window's windowless content")
struct WindowlessContentRoutingTests {

    @MainActor
    private final class Discovery {

        var geometry: WindowGeometryObservation?
        var auxiliaryKeyboardEndpoint: ResolvedInputEndpoint?

        /// False once the content stops proving it is the window's own.
        var isWindowlessContent = true

        /// How many times the windowless content route was asked.
        var windowlessReadings = 0

        var discovery: EndpointDiscovery {
            EndpointDiscovery(
                pointer: { _, _, chain, _ in .failure(.subtreeUnreadable(surface: chain.surface)) },
                keyboardContext: { [self] _, chain, _ in
                    auxiliaryKeyboardEndpoint.map { .success($0) }
                        ?? .failure(.subtreeUnreadable(surface: chain.surface))
                },
                identity: { [self] _ in geometry?.window.identity },
                focusedWindowNumber: { _ in nil },
                windowlessContent: { [self] _, point, chain, generation in
                    windowlessReadings += 1
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard isWindowlessContent,
                          let geometry,
                          let endpoint = ResolvedInputEndpoint(
                              kind                   : point == nil ? .keyboardContext : .pointer,
                              geometry               : geometry,
                              evidence               : .windowlessContentOfSurface,
                              relation               : .logicalSurface,
                              logicalSurface         : chain.surface,
                              accessibilityProcessID : chain.surface.processID,
                              selectionGeneration    : generation,
                              resolvedAtNanoseconds  : now,
                              // A parallel run takes longer than a real endpoint lives.
                              expiresAtNanoseconds   : now + 60_000_000_000,
                              focusedNodeWindowNumber: point == nil ? chain.surface.windowNumber : nil
                          )
                    else { return .failure(.subtreeUnreadable(surface: chain.surface)) }
                    return .success(endpoint)
                }
            )
        }
    }

    private struct Context {
        let seat       : AgentSeat
        let sender     : FakeSender
        let discovery  : Discovery
        let observation: SeatObservationReference
        let command    : InputCommand
    }

    private func context(modal: Bool, pointer: Bool) async throws -> Context {
        let sensing   = FakeSensing()
        let sender    = FakeSender()
        let discovery = Discovery()
        let reader    = ControlledSurfaceReader(sensing: sensing)
        let seat      = makeSeat(
            sensing  : sensing,
            sender   : sender,
            marker   : 2_115,
            reader   : reader,
            source   : ControlledObservationSource(sensing: sensing),
            clock    : ControlledContentClock(),
            endpoints: discovery.discovery
        )
        let window = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: AppKitPlatform()
        )
        if modal {
            reader.roles[window.id]  = .dialog
            reader.modals[window.id] = .application
            seat.refreshTargetReadings()
            seat.refreshTargetReadings()
        }
        let geometry = try #require(sensing.windowGeometryObservation(of: window.reference))
        discovery.geometry = geometry
        let point = CGPoint(x: geometry.window.frame.midX, y: geometry.window.frame.midY)
        return Context(
            seat       : seat,
            sender     : sender,
            discovery  : discovery,
            observation: try await observedReference(seat),
            command    : pointer
                ? .click(InputLocation(screenPoint: point, windowPointFromTop: CGPoint(x: 1, y: 1)))
                : KeyboardEndpointRoutingTests.escapeKey
        )
    }

    @Test("an ordinary window takes the click or the key on its windowless content itself",
          arguments: [true, false])
    func anOrdinaryWindowTakesItsWindowlessContentsInput(pointer: Bool) async throws {
        let context = try await context(modal: false, pointer: pointer)
        let turn    = try await context.seat.acquire()
        let receipt = try await context.seat.send(
            context.command,
            observation: context.observation,
            turn       : turn
        )

        #expect(context.sender.sent.count == 1)
        #expect(context.sender.addressed.last?.window.identity == context.observation.surface)
        #expect(context.sender.addressed.last?.platform is AppKitPlatform)
        // Keys take the same proof again at the boundary; a click is resolved once.
        if pointer {
            #expect(context.discovery.windowlessReadings == 1)
        } else {
            #expect(context.discovery.windowlessReadings >= 2)
        }
        try context.seat.confirm(receipt, .unknown)
        try context.seat.release(turn)
    }

    private func auxiliaryEndpoint(
        for context: Context,
        evidence: InputEndpointEvidence = .remoteContentOfSurface
    ) throws -> ResolvedInputEndpoint {
        let surface = context.observation.surface
        let geometry = try #require(context.discovery.geometry)
        let reference = FakeGeometry.reference(
            frame: CGRect(x: geometry.window.frame.midX, y: geometry.window.frame.midY,
                          width: 14, height: 14),
            processID: surface.processID + 1,
            windowNumber: 9090
        )
        let auxiliaryGeometry = try #require(WindowGeometryObservation(
            window: reference, scaleFactor: geometry.scaleFactor, version: geometry.version
        ))
        let now = DispatchTime.now().uptimeNanoseconds
        let candidate = ResolvedInputEndpoint(
            kind: .keyboardContext,
            geometry: auxiliaryGeometry,
            evidence: evidence,
            relation: .remoteContent,
            logicalSurface: surface,
            accessibilityProcessID: surface.processID,
            selectionGeneration: context.observation.selectionGeneration,
            resolvedAtNanoseconds: now,
            expiresAtNanoseconds: now + 60_000_000_000,
            focusedNodeWindowNumber: reference.windowNumber
        )
        return try #require(candidate)
    }

    @Test("a subtree's auxiliary window does not redirect a proved own windowless text control")
    func aWindowlessControlUsesItsOwnWindowDespiteAnAuxiliarySubtreeWindow() async throws {
        let context = try await context(modal: false, pointer: false)
        context.discovery.auxiliaryKeyboardEndpoint = try auxiliaryEndpoint(for: context)
        let turn = try await context.seat.acquire()
        let receipt = try await context.seat.send(
            context.command, observation: context.observation, turn: turn
        )
        #expect(context.sender.sent.count == 1)
        #expect(context.sender.addressed.last?.window.identity == context.observation.surface)
        #expect(context.sender.addressed.last?.platform is AppKitPlatform)
        #expect(context.discovery.windowlessReadings >= 2)
        try context.seat.confirm(receipt, .unknown)
        try context.seat.release(turn)
    }

    @Test("an auxiliary keyboard window still refuses without the own-content proof")
    func anAuxiliaryWindowDoesNotGrantMissingOwnContentProof() async throws {
        let context = try await context(modal: false, pointer: false)
        let endpoint = try auxiliaryEndpoint(for: context)
        context.discovery.auxiliaryKeyboardEndpoint = endpoint
        context.discovery.isWindowlessContent = false
        let turn = try await context.seat.acquire()
        await #expect(throws: SessionFailure.surfaceFamilyUnclassified(windowNumber: endpoint.identity.windowNumber)) {
            try await context.seat.send(context.command, observation: context.observation, turn: turn)
        }
        #expect(context.sender.sent.isEmpty)
        try context.seat.release(turn)
    }

    @Test("a modal never borrows the own-content route from an auxiliary subtree window")
    func aModalDoesNotBorrowOwnContentFromAnAuxiliaryWindow() async throws {
        let context = try await context(modal: true, pointer: false)
        let endpoint = try auxiliaryEndpoint(for: context)
        context.discovery.auxiliaryKeyboardEndpoint = endpoint
        let turn = try await context.seat.acquire()
        await #expect(throws: SessionFailure.surfaceFamilyUnclassified(windowNumber: endpoint.identity.windowNumber)) {
            try await context.seat.send(context.command, observation: context.observation, turn: turn)
        }
        #expect(context.discovery.windowlessReadings == 0)
        #expect(context.sender.sent.isEmpty)
        try context.seat.release(turn)
    }

    @Test("a focus naming another window is never overridden by the windowless route")
    func aNamedForeignFocusIsNotOverriddenByOwnContent() async throws {
        let context = try await context(modal: false, pointer: false)
        let endpoint = try auxiliaryEndpoint(for: context, evidence: .accessibilityNodeIdentity)
        context.discovery.auxiliaryKeyboardEndpoint = endpoint
        let turn = try await context.seat.acquire()
        await #expect(throws: SessionFailure.surfaceFamilyUnclassified(windowNumber: endpoint.identity.windowNumber)) {
            try await context.seat.send(context.command, observation: context.observation, turn: turn)
        }
        #expect(context.discovery.windowlessReadings == 0)
        #expect(context.sender.sent.isEmpty)
        try context.seat.release(turn)
    }

    @Test("a key whose focused control stops proving it during preparation posts nothing",
          arguments: [false, true])
    func aChangedProofAtTheFinalBoundaryPostsNothing(auxiliary: Bool) async throws {
        let context = try await context(modal: false, pointer: false)
        if auxiliary {
            context.discovery.auxiliaryKeyboardEndpoint = try auxiliaryEndpoint(for: context)
        }
        context.sender.onSendWait = { context.discovery.isWindowlessContent = false }
        let turn = try await context.seat.acquire()
        await #expect(throws: InputEndpointInvalidation.focusedNodeChanged) {
            try await context.seat.send(
                context.command,
                observation: context.observation,
                turn       : turn
            )
        }
        #expect(context.sender.sent.isEmpty)
        try context.seat.release(turn)
    }

    @Test("a modal surface never asks for the windowless content route, and keeps refusing",
          arguments: [true, false])
    func aModalSurfaceKeepsRefusing(pointer: Bool) async throws {
        let context = try await context(modal: true, pointer: pointer)
        let turn    = try await context.seat.acquire()
        await #expect(throws: InputEndpointRefusal.subtreeUnreadable(surface: context.observation.surface)) {
            try await context.seat.send(
                context.command,
                observation: context.observation,
                turn       : turn
            )
        }
        #expect(context.discovery.windowlessReadings == 0)
        #expect(context.sender.sent.isEmpty)
        try context.seat.release(turn)
    }
}
