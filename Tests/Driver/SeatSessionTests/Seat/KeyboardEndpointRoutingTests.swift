//
//  KeyboardEndpointRoutingTests.swift
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

/// Where the keys of one Command over a modal surface are addressed, and with
/// which recipe.
///
/// The keyboard's contract is not the mouse's. A gesture is decided by its
/// point and a key is not: it reaches the key window and its first responder,
/// so the context comes from the focused node the seat observed and from
/// nothing the pointer did. What is on trial here is which reading resolves it,
/// what a focus nobody can read produces, which recipe the Command is posted
/// with, and which process the hold registry has to be read against afterwards.
///
/// The discovery is injected, because it reads an accessibility tree and a
/// window server that do not exist in this tier. Every Window ID and process
/// identifier is the fakes' own: the live campaign's numbers are evidence of
/// what happened on one machine and are never written into a test.
@MainActor
@Suite("Routing keys to their endpoint")
struct KeyboardEndpointRoutingTests {

    typealias Panel = GestureEndpointRoutingTests.Panel

    static let escapeKey = InputCommand.key(virtualKey: 53, text: "")

    /// A panel whose focused node lives in the remote content, with the
    /// keyboard context resolved from it and the boundary reading agreeing.
    static func focusedInRemoteContent(
        _ panel      : Panel,
        _ observation: SeatObservationReference
    ) throws -> WindowGeometryObservation {

        let sheet   = try #require(panel.sheet.reference.identity)
        let content = try GestureEndpointRoutingTests.remoteContent(of: panel)
        let remote  = try #require(content.window.identity)

        panel.discovery.keyboardAnswer = .success(try GestureEndpointRoutingTests.endpoint(
            content,
            kind                   : .keyboardContext,
            relation               : .remoteContent,
            logicalSurface         : sheet,
            generation             : observation.selectionGeneration,
            hostProcessID          : panel.host.reference.processID,
            focusedNodeWindowNumber: GestureEndpointRoutingTests.remoteWindowNumber
        ))
        panel.discovery.identities[GestureEndpointRoutingTests.remoteWindowNumber] = remote
        panel.discovery.focusedWindowNumber = GestureEndpointRoutingTests.remoteWindowNumber
        return content
    }

    // MARK: The context comes from the focus, not from the pointer

    @Test("a key over the panel is addressed to the window the observed focus is in")
    func theContextComesFromTheFocusedNode() async throws {

        let panel       = try await GestureEndpointRoutingTests.panel()
        let observation = try await observedReference(panel.seat)
        let content     = try Self.focusedInRemoteContent(panel, observation)
        let remote      = try #require(content.window.identity)

        let turn    = try await panel.seat.acquire()
        let receipt = try await panel.seat.send(
            Self.escapeKey,
            observation: observation,
            turn       : turn
        )

        // The discovery that takes a point was never asked, which is the whole
        // difference between the two contracts.
        #expect(panel.discovery.points.isEmpty)
        #expect(panel.discovery.keyboardResolutions == 1)

        let addressed = try #require(panel.sender.addressed.last)
        #expect(addressed.window.identity == remote)
        #expect(addressed.window.identity?.ownerConnectionID == remote.ownerConnectionID)
        #expect(addressed.window.processID == remote.processID)
        #expect(addressed.window.processID != panel.host.reference.processID)
        #expect(addressed.window.processID != panel.sheet.reference.processID)

        // No coordinate is invented for a key: the Command that goes out is the
        // one the caller wrote, with no mouse location anywhere in it.
        let sent = try #require(panel.sender.sent.last?.command)
        #expect(sent == Self.escapeKey)
        #expect(sent.firstMouseScreenPoint == nil)
        #expect(!sent.hasMouseLocation)

        try panel.seat.confirm(receipt, .unknown)
        try panel.seat.release(turn)
    }

    @Test("the remote keyboard recipe is the qualified one, and the mouse's is not")
    func theRecipeIsTheKeyboardOne() async throws {

        let panel       = try await GestureEndpointRoutingTests.panel()
        let observation = try await observedReference(panel.seat)
        _ = try Self.focusedInRemoteContent(panel, observation)

        let turn    = try await panel.seat.acquire()
        let receipt = try await panel.seat.send(
            Self.escapeKey,
            observation: observation,
            turn       : turn
        )

        let platform = try #require(panel.sender.addressed.last?.platform)
        #expect(platform is RemoteKeyboardPlatform)
        // The three things the driver keys off the recipe: prepare the owner of
        // the reference it was handed, wait the recipe's own settle, restore.
        #expect(platform.preparation(for: Self.escapeKey) == .internalAppKitState)
        #expect(platform.preparationSettle(for: Self.escapeKey) == .milliseconds(50))
        // And the mouse's recipe on the same endpoint is untouched by it.
        #expect(AppKitPlatform().preparation(for: Self.escapeKey) == .none)
        // Prime the sheet hosting the remote view, even when the observation
        // captures its parent. Neither the parent nor the service hosts that view.
        let primed = try #require(platform.keyWindowPriming(for: Self.escapeKey)?.host)
        #expect(primed.windowNumber == panel.sheet.reference.windowNumber)
        #expect(primed.windowNumber != panel.host.reference.windowNumber)
        #expect(primed.windowNumber != GestureEndpointRoutingTests.remoteWindowNumber)

        try panel.seat.confirm(receipt, .unknown)
        try panel.seat.release(turn)
    }

    // MARK: A focus nobody can attest

    @Test("a focus the descent cannot read refuses, and the blocked host receives nothing")
    func anUnreadableFocusRefuses() async throws {

        let panel       = try await GestureEndpointRoutingTests.panel()
        let observation = try await observedReference(panel.seat)
        panel.discovery.keyboardAnswer = .failure(.subtreeUnreadable(
            surface: try #require(panel.sheet.reference.identity)
        ))

        let turn = try await panel.seat.acquire()
        await #expect(throws: InputEndpointRefusal.subtreeUnreadable(
            surface: try #require(panel.sheet.reference.identity)
        )) {
            try await panel.seat.send(
                Self.escapeKey,
                observation: observation,
                turn       : turn
            )
        }
        #expect(panel.sender.sent.isEmpty)
        #expect(panel.sender.addressed.isEmpty, "nothing was addressed, to the host least of all")
        try panel.seat.release(turn)
    }

    @Test("a focused node whose window server identity disagrees with itself refuses")
    func anAmbiguousFocusRefuses() async throws {

        let panel       = try await GestureEndpointRoutingTests.panel()
        let observation = try await observedReference(panel.seat)
        panel.discovery.keyboardAnswer = .failure(.identityChangedDuringDiscovery(
            windowNumber: GestureEndpointRoutingTests.remoteWindowNumber
        ))

        let turn = try await panel.seat.acquire()
        await #expect(throws: InputEndpointRefusal.identityChangedDuringDiscovery(
            windowNumber: GestureEndpointRoutingTests.remoteWindowNumber
        )) {
            try await panel.seat.send(
                Self.escapeKey,
                observation: observation,
                turn       : turn
            )
        }
        #expect(panel.sender.sent.isEmpty)
        try panel.seat.release(turn)
    }

    // MARK: The focus that moves between the resolution and the first event

    @Test("a focus that moved to another window retires the context, posting nothing")
    func aMovedFocusRetiresTheContext() async throws {

        let panel       = try await GestureEndpointRoutingTests.panel()
        let observation = try await observedReference(panel.seat)
        _ = try Self.focusedInRemoteContent(panel, observation)

        // The window is alive and unchanged; the focus is not in it any more.
        panel.discovery.afterResolving = {
            panel.discovery.focusedWindowNumber = GestureEndpointRoutingTests.sheetWindowNumber
        }

        let turn = try await panel.seat.acquire()
        await #expect(throws: InputEndpointInvalidation.focusedNodeChanged) {
            try await panel.seat.send(
                Self.escapeKey,
                observation: observation,
                turn       : turn
            )
        }
        #expect(panel.sender.sent.isEmpty)
        try panel.seat.release(turn)
    }

    @Test("a focus moved while remote preparation waits posts nothing")
    func aFocusMovedAtTheFinalBoundaryPostsNothing() async throws {
        let panel       = try await GestureEndpointRoutingTests.panel()
        let observation = try await observedReference(panel.seat)
        _ = try Self.focusedInRemoteContent(panel, observation)

        // The wait is the driver's preparation. The fake invokes the boundary
        // callback only after it, matching the first actual post rather than
        // the old compatibility callback before preparation began.
        panel.sender.onSendWait = {
            panel.discovery.focusedWindowNumber = GestureEndpointRoutingTests.sheetWindowNumber
        }

        let turn = try await panel.seat.acquire()
        await #expect(throws: InputEndpointInvalidation.focusedNodeChanged) {
            try await panel.seat.send(
                Self.escapeKey,
                observation: observation,
                turn       : turn
            )
        }
        #expect(panel.sender.sent.isEmpty)
        try panel.seat.release(turn)
    }

    @Test("a focus nothing answers for at the boundary retires the context too")
    func anUnreadableFocusAtTheBoundaryRetiresTheContext() async throws {

        let panel       = try await GestureEndpointRoutingTests.panel()
        let observation = try await observedReference(panel.seat)
        _ = try Self.focusedInRemoteContent(panel, observation)

        panel.discovery.afterResolving = { panel.discovery.focusedWindowNumber = nil }

        let turn = try await panel.seat.acquire()
        await #expect(throws: InputEndpointInvalidation.focusedNodeChanged) {
            try await panel.seat.send(
                Self.escapeKey,
                observation: observation,
                turn       : turn
            )
        }
        #expect(panel.sender.sent.isEmpty)
        try panel.seat.release(turn)
    }

    // MARK: The Shortcut keeps its own shape

    @Test("a character Shortcut carries no Unicode payload and takes the layout's own key")
    func aShortcutKeepsAnEmptyPayloadAndUsesTheLayout() async throws {

        let panel       = try await GestureEndpointRoutingTests.panel()
        let observation = try await observedReference(panel.seat)
        _ = try Self.focusedInRemoteContent(panel, observation)

        // The oracle is the installed layout, read here independently: the
        // virtual key is whatever that layout puts the character at, and never
        // a QWERTY constant written into the kit.
        let layout   = try #require(KeyboardLayoutReader.current())
        let expected = try #require(layout.resolve("a", modifiers: .command))

        let turn    = try await panel.seat.acquire()
        let receipt = try await panel.seat.send(
            .character("a", holding: .command),
            observation: observation,
            turn       : turn
        )

        guard case .key(let virtualKey, let text, let modifiers, _, let origin) =
            try #require(panel.sender.sent.last?.command)
        else {
            Issue.record("the Command that went out was not a key")
            return
        }
        #expect(virtualKey == expected.virtualKey)
        #expect(text.isEmpty, "a Shortcut is matched on its key equivalent, not on a payload")
        #expect(modifiers == .command)
        #expect(origin?.character == "a")
        #expect(receipt.layoutGeneration == layout.generation)

        try panel.seat.confirm(receipt, .unknown)
        try panel.seat.release(turn)
    }

    // MARK: What the hold registry is read against

    /// The driver records a hold on the process it posted to, which for this
    /// endpoint is the helper's. The seat's own accounting has to look there:
    /// the helper is in no record of the session, so reading only the adopted
    /// windows' processes would report a Turn as clean while a key is down
    /// inside somebody else's process.
    @Test("a key held on the remote recipient keeps the Turn from being given back")
    func aKeyHeldOnTheRemoteRecipientRefusesTheRelease() async throws {

        let panel       = try await GestureEndpointRoutingTests.panel()
        let observation = try await observedReference(panel.seat)
        let content     = try Self.focusedInRemoteContent(panel, observation)
        let remote      = try #require(content.window.identity)

        let turn    = try await panel.seat.acquire()
        let receipt = try await panel.seat.send(
            Self.escapeKey,
            observation: observation,
            turn       : turn
        )
        try panel.seat.confirm(receipt, .unknown)
        defer {
            _ = KeyHold.shared.releaseAll(
                owner    : turn.correlationID,
                processID: remote.processID
            )
        }

        #expect(panel.sender.addressed.last?.window.processID == remote.processID)
        KeyHold.shared.press(
            KeyHold.HeldKey(virtualKey: 56),
            owner    : turn.correlationID,
            processID: remote.processID
        )

        #expect(throws: SessionFailure.keysStillHeld(count: 1)) {
            try panel.seat.release(turn)
        }
    }

    @Test("a helper that closes while a key is down is still reported as stranded")
    func aClosedHelperIsStillReported() async throws {

        let panel       = try await GestureEndpointRoutingTests.panel()
        let observation = try await observedReference(panel.seat)
        let content     = try Self.focusedInRemoteContent(panel, observation)
        let remote      = try #require(content.window.identity)

        let turn    = try await panel.seat.acquire()
        let receipt = try await panel.seat.send(
            Self.escapeKey,
            observation: observation,
            turn       : turn
        )
        try panel.seat.confirm(receipt, .unknown)

        var issues: [SeatIssue] = []
        let listening = Task { @MainActor in
            for await event in panel.seat.events {
                if case .issueDetected(let issue, _) = event { issues.append(issue) }
            }
        }
        defer { listening.cancel() }

        KeyHold.shared.press(
            KeyHold.HeldKey(virtualKey: 55),
            owner    : turn.correlationID,
            processID: remote.processID
        )
        // The helper is gone: nothing answers for its window any more, and the
        // seat holds no record of its process to find it by.
        panel.discovery.identities[GestureEndpointRoutingTests.remoteWindowNumber] = nil
        panel.sensing.additionalWindows[GestureEndpointRoutingTests.remoteWindowNumber] = nil

        panel.seat.failFromHost([.displayChanged])

        for _ in 0 ..< 20 { await Task.yield() }
        #expect(issues.contains(.keysNotReleased))
        #expect(KeyHold.shared.held(processID: remote.processID).isEmpty)
    }
}
