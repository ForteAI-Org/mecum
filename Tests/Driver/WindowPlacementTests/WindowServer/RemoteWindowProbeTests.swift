//
//  RemoteWindowProbeTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/09/2026.
//

import CoreGraphics
import SeatCore
import Testing
@testable import WindowPlacement

/// The qualified reading of a window the public window list does not
/// enumerate, driven with the three window server questions replaced.
///
/// The oracle of every row is the fixture itself: the rectangle the fake
/// window server holds, the identities it answers in order, and the
/// containment of two rectangles computed here rather than asked of the code
/// under test. No row uses a Window ID from any live measurement: the
/// identifiers are this fixture's own, because the shipping code must not
/// recognise a number.
@Suite("The unlisted window reading")
struct RemoteWindowProbeTests {

    private static let surface = CGRect(x: 400, y: 300, width: 600, height: 400)
    private static let content = CGRect(x: 400, y: 340, width: 600, height: 360)

    private func identity(
        window    : Int,
        processID : Int32,
        connection: Int32,
        serial    : UInt32 = 1
    ) -> WindowIdentity {

        WindowIdentity(
            process: ProcessIdentity(
                processID       : processID,
                serialNumberHigh: 0,
                serialNumberLow : serial
            ),
            windowNumber     : window,
            ownerConnectionID: connection
        )
    }

    /// One reading against a fake window server. `identities` is answered in
    /// order, so a row can make the second reading disagree with the first.
    private func read(
        window     : Int = 902,
        container  : CGRect = RemoteWindowProbeTests.surface,
        tolerance  : CGFloat = 0,
        bounds     : CGRect?,
        identities : [WindowIdentity?],
        scaleFactor: @escaping (CGRect) -> CGFloat? = { _ in 2 }
    ) -> WindowGeometryObservation? {

        var answered = 0
        return RemoteWindowProbe.observation(
            of                  : window,
            containedIn         : container,
            containmentTolerance: tolerance,
            bounds              : { _ in bounds },
            identity            : { _ in
                defer { answered += 1 }
                return answered < identities.count ? identities[answered] : nil
            },
            scaleFactor         : scaleFactor,
            sequence            : 7
        )
    }

    @Test("a window with no entry in the public list still yields attested geometry")
    func unlistedWindowIsRead() throws {
        let remote = identity(window: 902, processID: 200, connection: 8000)
        let observation = try #require(
            read(bounds: Self.content, identities: [remote, remote])
        )

        // Nothing here consulted a window list: the frame is the one the fake
        // window server holds, and the identity is the one it attested.
        #expect(observation.window.frame == Self.content)
        #expect(observation.window.identity == remote)
        #expect(observation.window.processID == 200)
        #expect(observation.scaleFactor == 2)
        #expect(observation.version.sequence == 7)
    }

    @Test("a reused Window ID is refused: the two readings name different owners")
    func reusedWindowIdentifierIsRefused() {
        let first  = identity(window: 902, processID: 200, connection: 8000, serial: 1)
        let second = identity(window: 902, processID: 200, connection: 8000, serial: 2)

        #expect(first.windowNumber == second.windowNumber)
        #expect(first != second)
        #expect(read(bounds: Self.content, identities: [first, second]) == nil)
    }

    @Test("a helper replaced between the readings is refused")
    func replacedHelperIsRefused() {
        let first  = identity(window: 902, processID: 200, connection: 8000)
        let second = identity(window: 902, processID: 314, connection: 8100)

        #expect(read(bounds: Self.content, identities: [first, second]) == nil)
    }

    @Test("a window the identity chain cannot attest is refused before the bounds")
    func unattestedIdentityIsRefused() {
        #expect(read(bounds: Self.content, identities: [nil]) == nil)
        #expect(read(bounds: Self.content, identities: []) == nil)
    }

    @Test("an identity naming another window is refused")
    func identityOfAnotherWindowIsRefused() {
        let other = identity(window: 903, processID: 200, connection: 8000)
        #expect(read(bounds: Self.content, identities: [other, other]) == nil)
    }

    @Test("a rectangle that is not finite and positive is refused")
    func degenerateRectangleIsRefused() {
        let remote = identity(window: 902, processID: 200, connection: 8000)
        let empty  = CGRect(x: 400, y: 340, width: 0, height: 360)
        let huge   = CGRect(x: 400, y: 340, width: CGFloat.infinity, height: 360)

        #expect(read(bounds: nil, identities: [remote, remote]) == nil)
        #expect(read(bounds: empty, identities: [remote, remote]) == nil)
        #expect(read(bounds: huge, identities: [remote, remote]) == nil)
    }

    @Test("a rectangle outside the attested surface is refused")
    func rectangleOutsideTheSurfaceIsRefused() {
        let remote   = identity(window: 902, processID: 200, connection: 8000)
        let elsewhere = CGRect(x: 1400, y: 340, width: 600, height: 360)

        // The oracle: this rectangle is simply not inside the surface.
        #expect(!Self.surface.contains(elsewhere))
        #expect(read(bounds: elsewhere, identities: [remote, remote]) == nil)

        // And one that overlaps it partly is still not inside it.
        let overhanging = CGRect(x: 400, y: 340, width: 900, height: 360)
        #expect(!Self.surface.contains(overhanging))
        #expect(read(bounds: overhanging, identities: [remote, remote]) == nil)
    }

    @Test("the containment tolerance is the only slack, and zero by default")
    func containmentToleranceIsExplicit() throws {
        let remote = identity(window: 902, processID: 200, connection: 8000)
        let overhangingByOne = Self.surface.insetBy(dx: -1, dy: -1)

        #expect(read(bounds: overhangingByOne, identities: [remote, remote]) == nil)
        let allowed = try #require(
            read(tolerance: 1, bounds: overhangingByOne, identities: [remote, remote])
        )
        #expect(allowed.window.frame == overhangingByOne)
    }

    @Test("a rectangle with no unambiguous display scale is refused")
    func ambiguousScaleIsRefused() {
        let remote = identity(window: 902, processID: 200, connection: 8000)
        #expect(
            read(bounds: Self.content, identities: [remote, remote], scaleFactor: { _ in nil })
                == nil
        )
    }

    @Test("a container that is not a rectangle at all is refused")
    func degenerateContainerIsRefused() {
        let remote = identity(window: 902, processID: 200, connection: 8000)
        #expect(read(container: .null, bounds: Self.content, identities: [remote, remote]) == nil)
        #expect(read(window: 0, bounds: Self.content, identities: [remote, remote]) == nil)
    }

    @Test("a listed row that contradicts the recipient never falls back to SLS")
    func listedDiscordantRowRefusesWithoutFallback() throws {
        let expected = WindowReference(identity: identity(window: 902, processID: 200, connection: 8000), frame: Self.content)
        let listed = WindowReference(identity: identity(window: 902, processID: 314, connection: 8100), frame: Self.content)
        var unlistedCalls = 0

        let observation = RemoteWindowProbe.recipientGeometry(
            expected: expected,
            listed: .present(listed),
            unlisted: {
                unlistedCalls += 1
                return nil
            },
            scaleFactor: { _ in 2 },
            sequence: 1
        )

        #expect(observation == nil)
        #expect(unlistedCalls == 0)
    }

    @Test("only an absent public row may use the qualified fallback")
    func absentRowUsesFallbackButRefusedReadDoesNot() throws {
        let remote = identity(window: 902, processID: 200, connection: 8000)
        let expected = WindowReference(identity: remote, frame: Self.content)
        let fallback = try #require(read(bounds: Self.content, identities: [remote, remote]))
        var calls = 0

        let absent = RemoteWindowProbe.recipientGeometry(
            expected: expected, listed: .absent,
            unlisted: { calls += 1; return fallback }, scaleFactor: { _ in 2 }, sequence: 1
        )
        #expect(absent == fallback)
        #expect(calls == 1)
        let refused = RemoteWindowProbe.recipientGeometry(
            expected: expected, listed: .refused,
            unlisted: { calls += 1; return fallback }, scaleFactor: { _ in 2 }, sequence: 1
        )
        #expect(refused == nil)
        #expect(calls == 1)
    }
}
