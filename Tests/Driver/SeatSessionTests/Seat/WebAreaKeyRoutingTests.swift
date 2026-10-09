//
//  WebAreaKeyRoutingTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/10/2026.
//

import ApplicationServices
import CoreGraphics
import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// Where the keys of an ordinary window go when accessibility names no focused
/// control at all, as Safari does in the background (ADR 0014). The page's own
/// proof belongs to the resolver and is exercised in `DialogEndpointResolverTests`;
/// on trial here is when the seat asks for it, what else it requires of the
/// window server and the modal relation, and what reaches the driver.
@MainActor
@Suite("Routing keys to a page that names no focused control")
struct WebAreaKeyRoutingTests {

    @MainActor
    private final class Discovery {

        var geometry: WindowGeometryObservation?

        /// False once the page stops proving it is the window's own.
        var isProved = true

        /// How many times the web area route was asked, and what it was asked.
        var webAreaReadings = 0
        var pointsAsked: [CGPoint?] = []

        /// What a preparation exposes once the context was resolved: the web area route stops
        /// answering after this many readings, and a focused control resolves as one of these.
        var webAreaStopsAfter: Int?
        var focusedPageControl = false
        var focusedToolbarControl = false
        var focusedRemote: ResolvedInputEndpoint?

        private func endpoint(
            kind    : InputEndpointKind,
            evidence: InputEndpointEvidence,
            chain   : DialogEndpointResolver<AXUIElement>.SurfaceChain,
            generation: UInt64,
            focused : Int?
        ) -> ResolvedInputEndpoint? {
            guard let geometry else { return nil }
            let now = DispatchTime.now().uptimeNanoseconds
            return ResolvedInputEndpoint(
                kind                   : kind,
                geometry               : geometry,
                evidence               : evidence,
                relation               : .logicalSurface,
                logicalSurface         : chain.surface,
                accessibilityProcessID : chain.surface.processID,
                selectionGeneration    : generation,
                resolvedAtNanoseconds  : now,
                // A parallel run takes longer than a real endpoint lives.
                expiresAtNanoseconds   : now + 60_000_000_000,
                focusedNodeWindowNumber: focused
            )
        }

        var discovery: EndpointDiscovery {
            EndpointDiscovery(
                pointer: { _, _, chain, _ in .failure(.subtreeUnreadable(surface: chain.surface)) },
                // No focused control: every route that starts from one refuses.
                keyboardContext: { [self] _, chain, generation in
                    guard webAreaReadings >= 1 else { return .failure(.subtreeUnreadable(surface: chain.surface)) }
                    if let focusedRemote { return .success(focusedRemote) }
                    if focusedToolbarControl,
                       let found = endpoint(
                           kind: .keyboardContext, evidence: .attestedSurfaceItself, chain: chain,
                           generation: generation, focused: chain.surface.windowNumber
                       ) { return .success(found) }
                    return .failure(.subtreeUnreadable(surface: chain.surface))
                },
                identity: { [self] _ in geometry?.window.identity },
                focusedWindowNumber: { _ in nil },
                windowlessContent: { [self] _, _, chain, generation in
                    guard webAreaReadings >= 1, focusedPageControl,
                          let found = endpoint(
                              kind: .keyboardContext, evidence: .windowlessContentOfSurface, chain: chain,
                              generation: generation, focused: chain.surface.windowNumber
                          )
                    else { return .failure(.subtreeUnreadable(surface: chain.surface)) }
                    return .success(found)
                },
                webAreaKeyboardContext: { [self] _, point, chain, generation in
                    webAreaReadings += 1
                    pointsAsked.append(point)
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard isProved, webAreaStopsAfter.map({ webAreaReadings <= $0 }) ?? true,
                          let geometry,
                          let endpoint = ResolvedInputEndpoint(
                              kind                   : .keyboardContext,
                              geometry               : geometry,
                              evidence               : .windowlessContentWithoutFocus,
                              relation               : .logicalSurface,
                              logicalSurface         : chain.surface,
                              accessibilityProcessID : chain.surface.processID,
                              selectionGeneration    : generation,
                              resolvedAtNanoseconds  : now,
                              // A parallel run takes longer than a real endpoint lives.
                              expiresAtNanoseconds   : now + 60_000_000_000,
                              focusedNodeWindowNumber: nil
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
        let sensing    : FakeSensing
        let reader     : ControlledSurfaceReader
        let discovery  : Discovery
        let observation: SeatObservationReference
        let surface    : WindowSurface
        let command    : InputCommand
    }

    /// A window of the surface's own process the seat has read as `role` before the Command is observed.
    private static let otherWindowNumber = 9_191

    private func context(
        modal      : Bool = false,
        pointer    : Bool = false,
        otherWindow: SurfaceRole? = nil
    ) async throws -> Context {
        let sensing   = FakeSensing()
        let sender    = FakeSender()
        let discovery = Discovery()
        let reader    = ControlledSurfaceReader(sensing: sensing)
        let seat      = makeSeat(
            sensing  : sensing,
            sender   : sender,
            marker   : 2_116,
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
        let surface = WindowSurface(reference: window.reference, level: 0, isVisible: true)
        sensing.surfaces = [surface]
        if let otherWindow {
            let reference = FakeGeometry.reference(
                frame       : CGRect(x: 1700, y: 100, width: 66, height: 20),
                processID   : window.reference.processID,
                windowNumber: Self.otherWindowNumber
            )
            sensing.additionalWindows[Self.otherWindowNumber] = reference
            reader.roles[Self.otherWindowNumber] = otherWindow
            seat.refreshTargetReadings()
            seat.refreshTargetReadings()
        }
        let point = CGPoint(x: geometry.window.frame.midX, y: geometry.window.frame.midY)
        return Context(
            seat       : seat,
            sender     : sender,
            sensing    : sensing,
            reader     : reader,
            discovery  : discovery,
            observation: try await observedReference(seat),
            surface    : surface,
            command    : pointer
                ? .click(InputLocation(screenPoint: point, windowPointFromTop: CGPoint(x: 1, y: 1)))
                : KeyboardEndpointRoutingTests.escapeKey
        )
    }

    /// A window of the surface's own process, as the window server lists it.
    private func otherWindow(
        of context: Context,
        visible   : Bool = true
    ) -> WindowSurface {
        WindowSurface(
            reference: FakeGeometry.reference(
                frame       : CGRect(x: 1700, y: 100, width: 300, height: 200),
                processID   : context.surface.reference.processID,
                windowNumber: 9_191
            ),
            level    : 0,
            isVisible: visible
        )
    }

    private func send(_ context: Context) async throws -> InputReceipt {
        let turn = try await context.seat.acquire()
        defer { try? context.seat.release(turn) }
        return try await context.seat.send(
            context.command,
            observation: context.observation,
            turn       : turn
        )
    }

    private func refused(_ context: Context) async throws -> any Error {
        let turn = try await context.seat.acquire()
        defer { try? context.seat.release(turn) }
        do {
            _ = try await context.seat.send(context.command, observation: context.observation, turn: turn)
        } catch {
            return error
        }
        Issue.record("the key was admitted")
        return InputEndpointRefusal.noNodeAtPoint
    }

    // MARK: Admitted

    @Test("a key is admitted only when every condition holds, and goes to the window itself")
    func theKeyGoesToTheSurfaceWhenAllHold() async throws {
        let context = try await context()
        let receipt = try await send(context)

        #expect(context.sender.sent.count == 1)
        #expect(context.sender.addressed.last?.window.identity == context.observation.surface)
        #expect(context.sender.addressed.last?.platform is AppKitPlatform)
        // Resolved once for the Command and proved again at the boundary, with no point.
        #expect(context.discovery.webAreaReadings >= 2)
        #expect(context.discovery.pointsAsked.allSatisfy { $0 == nil })
        _ = receipt
    }

    @Test("a window of the process below the surface, or an invisible one above it, does not refuse")
    func windowsThatCannotHoldTheKeysDoNotRefuse() async throws {
        let below = try await context()
        below.sensing.surfaces = [below.surface, otherWindow(of: below)]
        _ = try await send(below)
        #expect(below.sender.sent.count == 1)

        // An alpha zero helper is no window anyone could type into.
        let helper = try await context()
        helper.sensing.surfaces = [otherWindow(of: helper, visible: false), helper.surface]
        _ = try await send(helper)
        #expect(helper.sender.sent.count == 1)
    }

    @Test("a window the seat read as a decoration or a tooltip above the surface is not one that holds keys",
          arguments: [SurfaceRole.decoration, .tooltip, .document, .dialog])
    func onlyWindowsNobodyOperatesAreIgnored(role: SurfaceRole) async throws {
        let context = try await context(otherWindow: role)
        let other = WindowSurface(
            reference: try #require(context.sensing.additionalWindows[Self.otherWindowNumber]),
            level    : 0,
            isVisible: true
        )
        context.sensing.surfaces = [other, context.surface]
        if role == .decoration || role == .tooltip {
            _ = try await send(context)
            #expect(context.sender.sent.count == 1)
        } else {
            let error = try await refused(context)
            #expect(error as? InputEndpointRefusal == .subtreeUnreadable(surface: context.observation.surface))
            #expect(context.sender.sent.isEmpty)
        }
    }

    // MARK: Refused

    @Test("a visible window of the process above the surface refuses")
    func anotherWindowAboveRefuses() async throws {
        let context = try await context()
        context.sensing.surfaces = [otherWindow(of: context), context.surface]
        let error = try await refused(context)
        #expect(error as? InputEndpointRefusal == .subtreeUnreadable(surface: context.observation.surface))
        #expect(context.sender.sent.isEmpty)
        #expect(context.discovery.webAreaReadings == 0, "the page is not read while the order refuses")
    }

    @Test("a window order that cannot be read, or that does not list the surface, refuses",
          arguments: [true, false])
    func anUnreadableOrderRefuses(listIsMissing: Bool) async throws {
        let context = try await context()
        context.sensing.surfaces = listIsMissing ? nil : []
        let error = try await refused(context)
        #expect(error as? InputEndpointRefusal == .subtreeUnreadable(surface: context.observation.surface))
        #expect(context.sender.sent.isEmpty)
    }

    @Test("an attested modal relation never asks for the page's route, and keeps refusing")
    func aModalSurfaceKeepsRefusing() async throws {
        let context = try await context(modal: true)
        let error = try await refused(context)
        #expect(error as? InputEndpointRefusal == .subtreeUnreadable(surface: context.observation.surface))
        #expect(context.discovery.webAreaReadings == 0)
        #expect(context.sender.sent.isEmpty)
    }

    @Test("a page that does not prove it is the window's own refuses")
    func aPageWithoutProofRefuses() async throws {
        let context = try await context()
        context.discovery.isProved = false
        let error = try await refused(context)
        #expect(error as? InputEndpointRefusal == .subtreeUnreadable(surface: context.observation.surface))
        #expect(context.discovery.webAreaReadings >= 1)
        #expect(context.sender.sent.isEmpty)
    }

    @Test("a click never takes the page's keyboard route")
    func aClickDoesNotAskForIt() async throws {
        let context = try await context(pointer: true)
        let error = try await refused(context)
        #expect(error is InputEndpointRefusal)
        #expect(context.discovery.webAreaReadings == 0)
        #expect(context.sender.sent.isEmpty)
    }

    // MARK: The boundary

    @Test("a page that stops proving it during preparation posts nothing")
    func aLostProofAtTheBoundaryPostsNothing() async throws {
        let context = try await context()
        context.sender.onSendWait = { context.discovery.isProved = false }
        let turn = try await context.seat.acquire()
        await #expect(throws: InputEndpointInvalidation.focusedNodeChanged) {
            try await context.seat.send(context.command, observation: context.observation, turn: turn)
        }
        #expect(context.sender.sent.isEmpty)
        try context.seat.release(turn)
    }

    @Test("a focus the preparation exposes is accepted only when it resolves back to this surface")
    func anExposedFocusIsAcceptedOnlyOnTheSameSurface() async throws {
        // A control of the page, windowless with the surface as its nearest window.
        let page = try await context()
        page.discovery.webAreaStopsAfter = 1
        page.discovery.focusedPageControl = true
        _ = try await send(page)
        #expect(page.sender.sent.count == 1)
        #expect(page.sender.addressed.last?.window.identity == page.observation.surface)

        // A control that names the surface window itself, as the toolbar's do.
        let toolbar = try await context()
        toolbar.discovery.webAreaStopsAfter = 1
        toolbar.discovery.focusedToolbarControl = true
        _ = try await send(toolbar)
        #expect(toolbar.sender.sent.count == 1)

        // A focus that resolves to another window's content, or to nothing, retires the context.
        let remote = try await context()
        remote.discovery.webAreaStopsAfter = 1
        remote.discovery.focusedRemote = try remoteEndpoint(for: remote)
        remote.sender.onSendWait = nil
        let remoteTurn = try await remote.seat.acquire()
        await #expect(throws: InputEndpointInvalidation.focusedNodeChanged) {
            try await remote.seat.send(remote.command, observation: remote.observation, turn: remoteTurn)
        }
        #expect(remote.sender.sent.isEmpty)
        try remote.seat.release(remoteTurn)

        let nothing = try await context()
        nothing.discovery.webAreaStopsAfter = 1
        let nothingTurn = try await nothing.seat.acquire()
        await #expect(throws: InputEndpointInvalidation.focusedNodeChanged) {
            try await nothing.seat.send(nothing.command, observation: nothing.observation, turn: nothingTurn)
        }
        #expect(nothing.sender.sent.isEmpty)
        try nothing.seat.release(nothingTurn)
    }

    @Test("an exposed focus does not outlast a window that opened above the surface")
    func anExposedFocusStillNeedsTheOrder() async throws {
        let context = try await context()
        context.discovery.webAreaStopsAfter = 1
        context.discovery.focusedPageControl = true
        context.sender.onSendWait = {
            context.sensing.surfaces = [self.otherWindow(of: context), context.surface]
        }
        let turn = try await context.seat.acquire()
        await #expect(throws: InputEndpointInvalidation.focusedNodeChanged) {
            try await context.seat.send(context.command, observation: context.observation, turn: turn)
        }
        #expect(context.sender.sent.isEmpty)
        try context.seat.release(turn)
    }

    /// Another process's window drawn inside the surface, as a remote panel's content is.
    private func remoteEndpoint(for context: Context) throws -> ResolvedInputEndpoint {
        let surface = context.observation.surface
        let geometry = try #require(context.discovery.geometry)
        let reference = FakeGeometry.reference(
            frame       : CGRect(x: geometry.window.frame.midX, y: geometry.window.frame.midY, width: 40, height: 40),
            processID   : surface.processID + 1,
            windowNumber: 9_292
        )
        let remoteGeometry = try #require(WindowGeometryObservation(
            window: reference, scaleFactor: geometry.scaleFactor, version: geometry.version
        ))
        let now = DispatchTime.now().uptimeNanoseconds
        return try #require(ResolvedInputEndpoint(
            kind: .keyboardContext, geometry: remoteGeometry, evidence: .remoteContentOfSurface,
            relation: .remoteContent, logicalSurface: surface, accessibilityProcessID: surface.processID,
            selectionGeneration: context.observation.selectionGeneration,
            resolvedAtNanoseconds: now, expiresAtNanoseconds: now + 60_000_000_000,
            focusedNodeWindowNumber: reference.windowNumber
        ))
    }

    @Test("a window of the process that opens above the surface during preparation posts nothing")
    func aWindowOpeningAboveAtTheBoundaryPostsNothing() async throws {
        let context = try await context()
        context.sender.onSendWait = {
            context.sensing.surfaces = [self.otherWindow(of: context), context.surface]
        }
        let turn = try await context.seat.acquire()
        await #expect(throws: InputEndpointInvalidation.focusedNodeChanged) {
            try await context.seat.send(context.command, observation: context.observation, turn: turn)
        }
        #expect(context.sender.sent.isEmpty)
        try context.seat.release(turn)
    }

    // MARK: The order predicate

    @Test("the surface is topmost only when it is listed, visible and first among visible windows")
    func topmostDecision() {
        let surface = FakeGeometry.identity()
        func listed(_ number: Int, visible: Bool = true) -> WindowSurface {
            WindowSurface(
                reference: FakeGeometry.reference(
                    frame       : FakeGeometry.userSeatWindow.frame,
                    windowNumber: number
                ),
                level    : 0,
                isVisible: visible
            )
        }
        let own = listed(FakeGeometry.windowNumber)
        #expect(AgentSeat.isTopmost(surface, among: [own]))
        #expect(AgentSeat.isTopmost(surface, among: [listed(1), own]) == false)
        #expect(AgentSeat.isTopmost(surface, among: [listed(1, visible: false), own]))
        #expect(AgentSeat.isTopmost(surface, among: [own, listed(1)]))
        #expect(AgentSeat.isTopmost(surface, among: [listed(1), own], ignoring: { $0.windowNumber == 1 }))
        #expect(AgentSeat.isTopmost(surface, among: [listed(1), listed(2), own],
                                    ignoring: { $0.windowNumber == 1 }) == false)
        #expect(AgentSeat.isTopmost(surface, among: [listed(FakeGeometry.windowNumber, visible: false)]) == false)
        #expect(AgentSeat.isTopmost(surface, among: []) == false)
        #expect(AgentSeat.isTopmost(surface, among: nil) == false)
    }
}
