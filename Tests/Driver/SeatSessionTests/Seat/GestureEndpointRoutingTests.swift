//
//  GestureEndpointRoutingTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/09/2026.
//

import CoreGraphics
import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// Where one mouse gesture over a modal surface is actually addressed, and with
/// which recipe.
///
/// The discovery of the recipient is injected, because it reads an
/// accessibility tree and a window server that do not exist in this tier. What
/// is on trial is everything around it: which point resolves the endpoint, how
/// many times it is resolved for one gesture, which reference reaches the
/// driver, which recipe is chosen, and what happens when the discovery answers
/// nothing.
///
/// The Window IDs and process identifiers are the fakes' own. The live
/// campaign's numbers are evidence of what happened on one machine and are
/// never written into a test.
@MainActor
@Suite("Routing a gesture to its endpoint")
struct GestureEndpointRoutingTests {

    static let sheetWindowNumber  = 878
    static let remoteWindowNumber = 879

    /// The discovery the seat would run against the live system, replaced by
    /// one whose answer a test writes and whose calls a test counts.
    @MainActor
    final class Discovery {

        /// Every resolution asked for, as the point it was asked about. One
        /// gesture must appear here exactly once.
        var points: [CGPoint] = []

        /// How many times the keyboard context was asked for, which takes no
        /// point at all.
        var keyboardResolutions = 0

        /// What the descent answers.
        var answer: Result<ResolvedInputEndpoint, InputEndpointRefusal> =
            .failure(.noNodeAtPoint)

        /// What the focused node's descent answers, when it is a different
        /// answer from the pointer's.
        var keyboardAnswer: Result<ResolvedInputEndpoint, InputEndpointRefusal>?

        var descendantKeyboardAnswer: Result<ResolvedInputEndpoint, InputEndpointRefusal>?
        var descendantKeyboardResolutions = 0

        /// What the leaf reading answers once a modal's discovery refused.
        var leafAnswer: Result<ResolvedInputEndpoint, InputEndpointRefusal>?

        /// What a modal's remote content reading answers for keys, and how
        /// many times it was asked.
        var remoteContentKeyboardAnswer: Result<ResolvedInputEndpoint, InputEndpointRefusal>?
        var remoteContentKeyboardResolutions = 0

        /// What a modal's focused content reading answers for keys, and how
        /// many times it was asked.
        var focusedContentKeyboardAnswer: Result<ResolvedInputEndpoint, InputEndpointRefusal>?
        var focusedContentKeyboardResolutions = 0

        /// What the window server answers for a Window ID at the boundary
        /// before the driver builds.
        var identities: [Int: WindowIdentity] = [:]

        /// The window the internal focus is in at the boundary, read once per
        /// keyboard Command.
        var focusedWindowNumber: Int?

        /// The fake panel service is expressly qualified. A remote PID alone is
        /// not enough to select the AppKit panel recipe.
        var qualifiesRemotePanelService = true

        /// The one foreign content window the modal's descendants name, read
        /// without any focus.
        var foreignContentWindow: Int?

        /// Applied the moment a resolution is answered, which is how a helper
        /// replaced between the discovery and the boundary is expressed.
        var afterResolving: (() -> Void)?

        var discovery: EndpointDiscovery {
            EndpointDiscovery(
                pointer: { [self] _, point, _, _ in
                    points.append(point)
                    afterResolving?()
                    return answer
                },
                keyboardContext: { [self] _, _, _ in
                    keyboardResolutions += 1
                    afterResolving?()
                    return keyboardAnswer ?? answer
                },
                identity: { [self] number in identities[number] },
                focusedWindowNumber: { [self] _ in focusedWindowNumber },
                qualifiedAppKitPanelService: { [self] _ in qualifiesRemotePanelService },
                focusedDescendantKeyboardContext: { [self] _, chain, _ in
                    descendantKeyboardResolutions += 1
                    return descendantKeyboardAnswer
                        ?? .failure(.subtreeUnreadable(surface: chain.surface))
                },
                leafSurface: { [self] _, _, chain, _ in
                    leafAnswer ?? .failure(.subtreeUnreadable(surface: chain.surface))
                },
                remoteContentKeyboardContext: { [self] _, chain, _ in
                    remoteContentKeyboardResolutions += 1
                    return remoteContentKeyboardAnswer
                        ?? .failure(.subtreeUnreadable(surface: chain.surface))
                },
                focusedContentKeyboardContext: { [self] _, chain, _ in
                    focusedContentKeyboardResolutions += 1
                    return focusedContentKeyboardAnswer
                        ?? .failure(.subtreeUnreadable(surface: chain.surface))
                },
                foreignContentWindow: { [self] _, _ in foreignContentWindow }
            )
        }
    }

    struct Panel {
        let seat     : AgentSeat
        let sensing  : FakeSensing
        let sender   : FakeSender
        let discovery: Discovery
        let host     : AdoptedWindow
        let sheet    : AdoptedWindow
    }

    /// A seat holding a host window driven with the Chromium recipe and a modal
    /// surface drawn inside it, with the modal relation attested.
    ///
    /// The host is deliberately the Chromium family: what the endpoint decides
    /// has to be visible against a host whose own recipe is the other one.
    static func panel(placing: FakePlacing = FakePlacing()) async throws -> Panel {

        let sensing   = FakeSensing()
        let sender    = FakeSender()
        let reader    = ControlledSurfaceReader(sensing: sensing)
        let discovery = Discovery()
        let seat      = makeSeat(
            sensing  : sensing,
            placing  : placing,
            sender   : sender,
            marker   : 1_903,
            reader   : reader,
            source   : ControlledObservationSource(sensing: sensing),
            clock    : ControlledContentClock(),
            endpoints: discovery.discovery
        )

        let host = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: ChromiumPlatform()
        )
        let inbound = FakeGeometry.reference(
            frame       : FakeGeometry.adoptedWindow.frame.offsetBy(dx: 60, dy: 60),
            windowNumber: Self.sheetWindowNumber
        )
        sensing.additionalWindows[Self.sheetWindowNumber] = inbound
        let sheet = try await seat.adopt(inbound, platform: ChromiumPlatform())

        // The window server answers where the sheet came to rest, which is what
        // the guard before every Command compares the record against.
        sensing.additionalWindows[Self.sheetWindowNumber] = sheet.reference

        reader.roles[sheet.id]  = .dialog
        reader.modals[sheet.id] = .window(try #require(host.reference.identity))
        seat.refreshTargetReadings()
        seat.refreshTargetReadings()

        return Panel(
            seat     : seat,
            sensing  : sensing,
            sender   : sender,
            discovery: discovery,
            host     : host,
            sheet    : sheet
        )
    }

    /// The remote panel content: another process's window, drawn wholly inside
    /// the modal surface, with an identity of its own end to end.
    static func remoteContent(of panel: Panel) throws -> WindowGeometryObservation {
        try #require(WindowGeometryObservation(
            window: FakeGeometry.reference(
                frame       : panel.sheet.reference.frame.insetBy(dx: 20, dy: 20),
                processID   : FakeGeometry.distinctProcessID(),
                windowNumber: Self.remoteWindowNumber
            ),
            scaleFactor: 2,
            version    : GeometryObservationVersion(observerGeneration: 3, sequence: 9)
        ))
    }

    static func endpoint(
        _ geometry    : WindowGeometryObservation,
        kind          : InputEndpointKind = .pointer,
        relation      : InputEndpointRelation,
        logicalSurface: WindowIdentity,
        generation    : UInt64,
        hostProcessID : Int32,
        focusedNodeWindowNumber: Int? = nil,
        lifetimeNanoseconds: UInt64 = 500_000_000
    ) throws -> ResolvedInputEndpoint {

        let now = DispatchTime.now().uptimeNanoseconds
        return try #require(ResolvedInputEndpoint(
            kind                  : kind,
            geometry              : geometry,
            evidence              : relation == .remoteContent
                ? .accessibilityNodeIdentity
                : .attestedSurfaceItself,
            relation              : relation,
            logicalSurface        : logicalSurface,
            accessibilityProcessID: hostProcessID,
            selectionGeneration   : generation,
            resolvedAtNanoseconds : now,
            expiresAtNanoseconds  : now &+ lifetimeNanoseconds,
            focusedNodeWindowNumber: focusedNodeWindowNumber
        ))
    }

    /// A point well inside the modal surface, which is where a control is.
    static func insideSheet(_ panel: Panel) -> CGPoint {
        CGPoint(x: panel.sheet.reference.frame.midX, y: panel.sheet.reference.frame.midY)
    }

    static func click(at point: CGPoint, count: Int = 1) -> InputCommand {
        .click(InputLocation(screenPoint: point, windowPointFromTop: CGPoint(x: 1, y: 1)), count: count)
    }

    // MARK: The measured remote recipe

    @Test("a click train over the panel keeps its recipient and count", arguments: [1, 2, 3, 32])
    func theRemoteContentIsTheRecipient(count: Int) async throws {

        let panel      = try await Self.panel()
        let observation = try await observedReference(panel.seat)
        let sheet      = try #require(panel.sheet.reference.identity)
        #expect(observation.role == .hostedSheet(sheet: sheet))

        let content  = try Self.remoteContent(of: panel)
        let remote   = try #require(content.window.identity)
        panel.discovery.answer = .success(try Self.endpoint(
            content,
            relation      : .remoteContent,
            logicalSurface: sheet,
            generation    : observation.selectionGeneration,
            hostProcessID : panel.host.reference.processID
        ))
        panel.discovery.qualifiesRemotePanelService = true
        panel.discovery.identities[Self.remoteWindowNumber] = remote

        let point   = Self.insideSheet(panel)
        let turn    = try await panel.seat.acquire()
        let receipt = try await panel.seat.send(
            Self.click(at: point, count: count),
            observation: observation,
            turn       : turn
        )

        let addressed = try #require(panel.sender.addressed.last)
        // The three fields the driver keys off this one reference: field 51,
        // field 52 and `postToPid`, all three the content's and none the host's.
        #expect(addressed.window.identity == remote)
        #expect(addressed.window.windowNumber == Self.remoteWindowNumber)
        #expect(addressed.window.identity?.ownerConnectionID == remote.ownerConnectionID)
        #expect(addressed.window.processID == remote.processID)
        #expect(addressed.window.processID != panel.host.reference.processID)
        #expect(addressed.window.processID != panel.sheet.reference.processID)

        // The recipe is the measured one and not the host's, although the host
        // is the family that prepares.
        #expect(addressed.platform is AppKitPlatform)
        #expect(addressed.platform.preparation(for: Self.click(at: point)) == .none)
        #expect(panel.seat.session[panel.sheet.id]?.platform is ChromiumPlatform,
                "the surface record still carries its own application's family")

        // The screen point is carried through; only the window-local half is
        // measured again, from the endpoint's own origin.
        let sent = try #require(panel.sender.sent.last?.command)
        guard case .click(let location, _, let sentCount) = sent else {
            Issue.record("the Command that went out was not the click")
            return
        }
        #expect(sentCount == count)
        #expect(panel.discovery.points == [point])
        #expect(location.screenPoint == point)
        #expect(location.windowPointFromTop == CGPoint(
            x: point.x - content.window.frame.minX,
            y: point.y - content.window.frame.minY
        ))
        #expect(location.observedGeometry?.version == content.version,
                "the point is expressed against the reading the endpoint carries")

        try panel.seat.confirm(receipt, .unknown)
        try panel.seat.release(turn)
    }

    // MARK: One endpoint for the whole gesture

    @Test("a drag is resolved once, from the point of the down, and never switches process")
    func theWholeGestureStaysOnTheDownEndpoint() async throws {

        let panel       = try await Self.panel()
        let observation = try await observedReference(panel.seat)
        let sheet       = try #require(panel.sheet.reference.identity)

        let content = try Self.remoteContent(of: panel)
        let remote  = try #require(content.window.identity)
        panel.discovery.answer = .success(try Self.endpoint(
            content,
            relation      : .remoteContent,
            logicalSurface: sheet,
            generation    : observation.selectionGeneration,
            hostProcessID : panel.host.reference.processID
        ))
        panel.discovery.qualifiesRemotePanelService = true
        panel.discovery.identities[Self.remoteWindowNumber] = remote

        let frame  = panel.sheet.reference.frame
        let points = [
            CGPoint(x: frame.midX - 40, y: frame.midY - 40),
            CGPoint(x: frame.midX,      y: frame.midY),
            CGPoint(x: frame.midX + 40, y: frame.midY + 40),
        ]
        let drag = InputCommand.drag(points: points.map {
            InputLocation(screenPoint: $0, windowPointFromTop: .zero)
        })

        let turn    = try await panel.seat.acquire()
        let receipt = try await panel.seat.send(drag, observation: observation, turn: turn)

        #expect(panel.discovery.points == [points[0]],
                "one gesture is one resolution, and it is the point of the down")
        #expect(panel.sender.addressed.count == 1)
        #expect(panel.sender.addressed.last?.window.identity == remote)

        guard case .drag(let routed, _) = try #require(panel.sender.sent.last?.command) else {
            Issue.record("the Command that went out was not the drag")
            return
        }
        #expect(routed.map(\.screenPoint) == points)
        #expect(routed.allSatisfy { $0.observedGeometry?.window.identity == remote },
                "every step and the release are expressed against the down's endpoint")

        try panel.seat.confirm(receipt, .unknown)
        try panel.seat.release(turn)
    }

    @Test("a helper replaced between the discovery and the boundary refuses, posting nothing")
    func aReplacedHelperRefusesRatherThanSwitching() async throws {

        let panel       = try await Self.panel()
        let observation = try await observedReference(panel.seat)
        let sheet       = try #require(panel.sheet.reference.identity)

        let content = try Self.remoteContent(of: panel)
        let remote  = try #require(content.window.identity)
        panel.discovery.answer = .success(try Self.endpoint(
            content,
            relation      : .remoteContent,
            logicalSurface: sheet,
            generation    : observation.selectionGeneration,
            hostProcessID : panel.host.reference.processID
        ))
        panel.discovery.qualifiesRemotePanelService = true
        panel.discovery.identities[Self.remoteWindowNumber] = remote

        // The service is replaced between the resolution and the first event:
        // the same Window ID under another process lifetime.
        panel.discovery.afterResolving = {
            panel.discovery.identities[Self.remoteWindowNumber] = FakeGeometry.identity(
                processID   : remote.processID,
                windowNumber: Self.remoteWindowNumber,
                lifetime    : remote.process.serialNumberHigh &+ 1
            )
        }

        let turn = try await panel.seat.acquire()
        await #expect(throws: InputEndpointInvalidation.identityChanged) {
            try await panel.seat.send(
                Self.click(at: Self.insideSheet(panel)),
                observation: observation,
                turn       : turn
            )
        }
        #expect(panel.sender.sent.isEmpty, "nothing went out, to either process")
        try panel.seat.release(turn)
    }

    @Test("a selection changed while driver preparation waits posts nothing")
    func aChangedSelectionAtTheFinalBoundaryPostsNothing() async throws {
        let sensing = FakeSensing()
        let sender  = FakeSender()
        let reader  = ControlledSurfaceReader(sensing: sensing)
        let seat    = makeSeat(
            sensing: sensing,
            sender : sender,
            marker : 1_907,
            reader : reader,
            source : ControlledObservationSource(sensing: sensing),
            clock  : ControlledContentClock()
        )
        let first = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: AppKitPlatform()
        )
        let secondReference = ObservationAdmissionTests.reference(
            ObservationAdmissionTests.secondWindowNumber
        )
        sensing.additionalWindows[secondReference.windowNumber] = secondReference
        let second = try await seat.adopt(secondReference, platform: AppKitPlatform())
        let secondIdentity = try #require(second.reference.identity)

        _ = try await seat.switchTarget(to: first)
        let observation = try await observedReference(seat)
        #expect(seat.currentTarget?.id == first.id)

        var didMoveTarget = false
        sender.onSendWait = {
            reader.recency = [RecencyClaim(
                surface              : secondIdentity,
                signal               : .returnedToFront,
                provenance           : .qualifiedFrontOrderAttestation,
                origin               : .application(provenance: .qualifiedRaiseAttribution),
                observedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
            )]
            seat.refreshTargetReadings()
            didMoveTarget = seat.currentTarget?.id == second.id
        }

        // This runs after the fake's preparation wait and immediately before
        // its counted post. The old extension callback ran before this wait,
        // so it recorded one stale gesture.
        let turn = try await seat.acquire()
        await #expect(throws: ObservationAdmissionRefusal.self) {
            try await seat.send(
                .click(InputLocation(
                    screenPoint: CGPoint(x: first.reference.frame.midX, y: first.reference.frame.midY),
                    windowPointFromTop: CGPoint(x: 50, y: 50)
                )),
                observation: observation,
                turn       : turn
            )
        }
        #expect(didMoveTarget, "the production fold must have moved the operating target")
        #expect(sender.sent.isEmpty)
        try seat.release(turn)
    }

    @Test("an endpoint that expires during driver preparation posts nothing")
    func anExpiredEndpointAtTheFinalBoundaryPostsNothing() async throws {
        let panel       = try await Self.panel()
        let observation = try await observedReference(panel.seat)
        let sheet       = try #require(panel.sheet.reference.identity)
        let content     = try Self.remoteContent(of: panel)
        let remote      = try #require(content.window.identity)
        panel.discovery.answer = .success(try Self.endpoint(
            content,
            relation      : .remoteContent,
            logicalSurface: sheet,
            generation    : observation.selectionGeneration,
            hostProcessID : panel.host.reference.processID,
            lifetimeNanoseconds: 100_000_000
        ))
        panel.discovery.identities[Self.remoteWindowNumber] = remote
        var reachedPreparation = false
        panel.sender.onSendWait = {
            reachedPreparation = true
            try? await Task.sleep(for: .milliseconds(150))
        }

        let turn = try await panel.seat.acquire()
        await #expect(throws: InputEndpointInvalidation.expired) {
            try await panel.seat.send(
                Self.click(at: Self.insideSheet(panel)),
                observation: observation,
                turn       : turn
            )
        }
        #expect(reachedPreparation, "the endpoint must expire during preparation, not before it")
        #expect(panel.sender.sent.isEmpty)
        try panel.seat.release(turn)
    }

    // MARK: What is never forwarded to the blocked host

    @Test("a point outside the modal surface is refused, not delivered to the window it blocks")
    func aPointOutsideTheSheetIsNotForwardedToTheHost() async throws {

        let panel       = try await Self.panel()
        let observation = try await observedReference(panel.seat)

        // Inside the picture, which is the host's, and outside the modal drawn
        // in it: the old routing answered this with the host.
        let outside = CGPoint(
            x: panel.sheet.reference.frame.minX - 30,
            y: panel.sheet.reference.frame.minY - 30
        )
        #expect(!panel.sheet.reference.frame.contains(outside))

        let turn = try await panel.seat.acquire()
        await #expect(throws: InputEndpointRefusal.pointOutsideSurface) {
            try await panel.seat.send(
                Self.click(at: outside),
                observation: observation,
                turn       : turn
            )
        }
        #expect(panel.sender.sent.isEmpty)
        #expect(panel.discovery.points.isEmpty,
                "a point that names no relation is refused before any descent")
        try panel.seat.release(turn)
    }

    @Test("a discovery that names no recipient refuses instead of falling back to the host")
    func anAmbiguousDiscoveryRefuses() async throws {

        let panel       = try await Self.panel()
        let observation = try await observedReference(panel.seat)
        panel.discovery.answer = .failure(.subtreeUnreadable(
            surface: try #require(panel.sheet.reference.identity)
        ))

        let turn = try await panel.seat.acquire()
        await #expect(throws: InputEndpointRefusal.self) {
            try await panel.seat.send(
                Self.click(at: Self.insideSheet(panel)),
                observation: observation,
                turn       : turn
            )
        }
        #expect(panel.sender.sent.isEmpty)
        try panel.seat.release(turn)
    }

    @Test("a modal whose discovery refused and that is one accessibility leaf takes the click itself")
    func aLeafModalTakesTheClickItself() async throws {

        // The leaf decision is the resolver's, proven where it is written; on
        // trial here is only that a modal's refusal asks it last.
        let panel       = try await Self.panel()
        let observation = try await observedReference(panel.seat)
        let sheet       = try #require(panel.sheet.reference.identity)
        panel.discovery.answer = .failure(.notContainedInSurface(windowNumber: panel.host.id))
        panel.discovery.leafAnswer = .success(try Self.endpoint(
            try #require(WindowGeometryObservation(
                window     : panel.sheet.reference,
                scaleFactor: 2,
                version    : GeometryObservationVersion(observerGeneration: 4, sequence: 11)
            )),
            relation      : .logicalSurface,
            logicalSurface: sheet,
            generation    : observation.selectionGeneration,
            hostProcessID : panel.host.reference.processID,
            // A parallel run takes longer than a real endpoint lives.
            lifetimeNanoseconds: 60_000_000_000
        ))
        panel.discovery.identities[Self.sheetWindowNumber] = sheet

        let turn    = try await panel.seat.acquire()
        let receipt = try await panel.seat.send(
            Self.click(at: Self.insideSheet(panel)),
            observation: observation,
            turn       : turn
        )

        #expect(panel.sender.addressed.last?.window.identity == sheet)
        #expect(panel.sender.sent.count == 1)
        try panel.seat.confirm(receipt, .unknown)
        try panel.seat.release(turn)
    }

    @Test("a modal host its application reports elsewhere is written back where it is shown, before the Command")
    func aStaleReportedPositionIsWrittenBack() async throws {

        let placing     = FakePlacing()
        let panel       = try await Self.panel(placing: placing)
        let observation = try await observedReference(panel.seat)
        let host        = panel.host.reference
        let shown       = try #require(panel.sensing.windowGeometry(of: host.windowNumber)).frame
        // Measured on 30/09/2026: Photoshop reported its Save panel 2036 by 1347
        // points from where the window server showed it.
        placing.bodyFrames[host.windowNumber] = shown.offsetBy(dx: -2036, dy: -1347)
        placing.moves = []

        let turn = try await panel.seat.acquire()
        _ = try? await panel.seat.send(
            Self.click(at: Self.insideSheet(panel)),
            observation: observation,
            turn       : turn
        )
        #expect(placing.moves.first == shown.origin)
        try? panel.seat.release(turn)

        // Two sources that agree are left alone.
        placing.bodyFrames[host.windowNumber] = shown
        placing.moves = []
        let again = try await panel.seat.acquire()
        _ = try? await panel.seat.send(
            Self.click(at: Self.insideSheet(panel)),
            observation: try await observedReference(panel.seat),
            turn       : again
        )
        #expect(placing.moves.isEmpty)
        try? panel.seat.release(again)
    }

    // MARK: The surface the seat holds answering for itself

    @Test("a surface that answers for itself keeps its application's family and its current frame")
    func theSurfaceItselfKeepsItsOwnFamily() async throws {

        let panel       = try await Self.panel()
        let observation = try await observedReference(panel.seat)
        let sheet       = try #require(panel.sheet.reference.identity)

        // The same window, read again by the discovery: the frame of that
        // reading is what the result carries, and not the record's.
        let moved = try #require(WindowGeometryObservation(
            window     : panel.sheet.reference.replacingFrame(
                panel.sheet.reference.frame.offsetBy(dx: 12, dy: 8)
            ),
            scaleFactor: 2,
            version    : GeometryObservationVersion(observerGeneration: 4, sequence: 11)
        ))
        panel.discovery.answer = .success(try Self.endpoint(
            moved,
            relation      : .logicalSurface,
            logicalSurface: sheet,
            generation    : observation.selectionGeneration,
            hostProcessID : panel.host.reference.processID
        ))
        panel.discovery.identities[Self.sheetWindowNumber] = sheet

        let point   = Self.insideSheet(panel)
        let turn    = try await panel.seat.acquire()
        let receipt = try await panel.seat.send(
            Self.click(at: point),
            observation: observation,
            turn       : turn
        )

        let addressed = try #require(panel.sender.addressed.last)
        #expect(addressed.window.identity == sheet)
        #expect(addressed.window.frame == moved.window.frame,
                "the reference handed over is the endpoint's current reading")
        #expect(addressed.platform is ChromiumPlatform,
                "a modal of the driven application is not AppKit by rule")

        guard case .click(let location, _, _) = try #require(panel.sender.sent.last?.command) else {
            Issue.record("the Command that went out was not the click")
            return
        }
        #expect(location.screenPoint == point)
        #expect(location.windowPointFromTop == CGPoint(
            x: point.x - moved.window.frame.minX,
            y: point.y - moved.window.frame.minY
        ))

        try panel.seat.confirm(receipt, .unknown)
        try panel.seat.release(turn)
    }

    // MARK: The explicit unknown

    @Test("a Command the surface's evidence does not cover refuses rather than defaulting")
    func anUnclassifiedSurfaceRefuses() async throws {

        let panel       = try await Self.panel()
        let observation = try await observedReference(panel.seat)

        // A key is resolved from the focused node, and a focused node nothing
        // answers for refuses. The old rule answered AppKit and posted.
        panel.discovery.keyboardAnswer = .failure(.subtreeUnreadable(
            surface: try #require(panel.sheet.reference.identity)
        ))
        let turn = try await panel.seat.acquire()
        await #expect(throws: InputEndpointRefusal.self) {
            try await panel.seat.send(
                .key(virtualKey: 53, text: ""),
                observation: observation,
                turn       : turn
            )
        }
        #expect(panel.sender.sent.isEmpty)
        try panel.seat.release(turn)
    }

    @Test("a foreign window without a qualified panel backend is refused before posting")
    func unqualifiedRemoteContentRefuses() async throws {

        let panel       = try await Self.panel()
        let observation = try await observedReference(panel.seat)
        let sheet       = try #require(panel.sheet.reference.identity)
        let content     = try Self.remoteContent(of: panel)
        let remote      = try #require(content.window.identity)
        panel.discovery.answer = .success(try Self.endpoint(
            content,
            relation      : .remoteContent,
            logicalSurface: sheet,
            generation    : observation.selectionGeneration,
            hostProcessID : panel.host.reference.processID
        ))
        panel.discovery.qualifiesRemotePanelService = false
        panel.discovery.identities[Self.remoteWindowNumber] = remote

        let turn = try await panel.seat.acquire()
        await #expect(throws: SessionFailure.self) {
            try await panel.seat.send(
                Self.click(at: Self.insideSheet(panel)),
                observation: observation,
                turn       : turn
            )
        }
        #expect(panel.sender.sent.isEmpty)
        try panel.seat.release(turn)
    }

    @Test("a held modal is a remote file panel only when its one foreign content is the qualified service's")
    func aRemoteFilePanelIsTheQualifiedServicesContent() async throws {

        let panel  = try await Self.panel()
        let remote = try #require(try Self.remoteContent(of: panel).window.identity)
        panel.discovery.identities[Self.remoteWindowNumber] = remote
        #expect(panel.seat.openDialogs == [try #require(panel.sheet.reference.identity)])
        #expect(!panel.seat.holdsRemoteFilePanel, "an ordinary dialog names no foreign content")

        panel.discovery.foreignContentWindow = Self.remoteWindowNumber
        #expect(panel.seat.holdsRemoteFilePanel)

        panel.discovery.qualifiesRemotePanelService = false
        #expect(!panel.seat.holdsRemoteFilePanel, "another process's content is not the panel service")
    }

    // MARK: The classification on its own

    @Test("an ordinary target is the driven application, whatever the endpoint says")
    func anOrdinaryTargetNeedsNoEndpoint() async throws {

        let context     = try await ObservationAdmissionTests.composed(marker: 1_904)
        let observation = try await observedReference(context.seat)

        #expect(SurfaceInputClassification.of(observation, endpoint: nil) == .drivenApplication)
    }

    @Test("a same-process child has the application recipe even with a distinct Window ID")
    func sameProcessChildKeepsApplicationProfile() async throws {
        let context = try await ObservationAdmissionTests.composed(marker: 1_905)
        let observation = try await observedReference(context.seat)
        let surface = observation.surface
        let childIdentity = WindowIdentity(
            process: surface.process,
            windowNumber: Self.remoteWindowNumber,
            ownerConnectionID: surface.ownerConnectionID &+ 1
        )
        let child = WindowReference(
            identity: childIdentity,
            frame: observation.observedFrame.insetBy(dx: 10, dy: 10)
        )
        let geometry = try #require(WindowGeometryObservation(
            window: child, scaleFactor: 2,
            version: GeometryObservationVersion(observerGeneration: 1, sequence: 1)
        ))
        let endpoint = try Self.endpoint(
            geometry, relation: .remoteContent,
            logicalSurface: surface, generation: observation.selectionGeneration,
            hostProcessID: surface.processID
        )
        #expect(SurfaceInputClassification.of(
            observation, endpoint: endpoint, remoteAppKitPanelServiceQualified: true
        ) == .drivenApplication)
    }

    @Test("each classification answers its own recipe, and the unknown answers none")
    func theClassificationTable() throws {

        let click = Self.click(at: CGPoint(x: 10, y: 10))
        let key   = InputCommand.key(virtualKey: 53, text: "")
        let host  = ChromiumPlatform()

        #expect(SurfaceInputClassification.drivenApplication
            .platform(for: click, ofDrivenApplication: host) is ChromiumPlatform)
        #expect(SurfaceInputClassification.remotePanelContent
            .platform(for: click, ofDrivenApplication: host) is AppKitPlatform)
        #expect(SurfaceInputClassification.remotePanelContent
            .platform(for: key, ofDrivenApplication: host) is RemoteKeyboardPlatform,
                "a key on a remote endpoint takes the keyboard recipe, not the mouse's")
        #expect(SurfaceInputClassification.unknown
            .platform(for: click, ofDrivenApplication: host) == nil)
        #expect(SurfaceInputClassification.unknown
            .platform(for: key, ofDrivenApplication: host) == nil)

        // Prepared keys belong to a UXP application's leaf modal only.
        let leafKey = SurfaceInputClassification.leafSurfaceOfDrivenApplication
            .platform(for: key, ofDrivenApplication: UXPPlatform())
        #expect((leafKey as? UXPPlatform)?.preparation(for: key) == .internalAppKitState)
        #expect(SurfaceInputClassification.drivenApplication
            .platform(for: key, ofDrivenApplication: UXPPlatform())?.preparation(for: key) == Preparation.none)
        #expect(SurfaceInputClassification.leafSurfaceOfDrivenApplication
            .platform(for: key, ofDrivenApplication: host) is ChromiumPlatform)
    }
}
