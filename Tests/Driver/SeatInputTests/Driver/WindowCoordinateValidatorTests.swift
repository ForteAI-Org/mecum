//
//  WindowCoordinateValidatorTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import CoreGraphics
import SeatCore
@testable import SeatInput
import Testing

@Suite("Coordinate validity before the first event is built")
struct WindowCoordinateValidatorTests {

    private static let identity = WindowIdentity(
        process: ProcessIdentity(
            processID       : 42,
            serialNumberHigh: 3,
            serialNumberLow : 5
        ),
        windowNumber     : 117,
        ownerConnectionID: 19
    )

    private static func observation(
        identity   : WindowIdentity = identity,
        frame      : CGRect = CGRect(x: 100, y: 200, width: 400, height: 300),
        scaleFactor: CGFloat = 2,
        sequence   : UInt64 = 1
    ) throws -> WindowGeometryObservation {
        try #require(WindowGeometryObservation(
            window     : WindowReference(identity: identity, frame: frame),
            scaleFactor: scaleFactor,
            version    : GeometryObservationVersion(
                observerGeneration: 1,
                sequence          : sequence
            )
        ))
    }

    private static func location(
        in observation: WindowGeometryObservation,
        local         : CGPoint = CGPoint(x: 40, y: 60)
    ) -> InputLocation {
        InputLocation(
            screenPoint: CGPoint(
                x: observation.window.frame.minX + local.x,
                y: observation.window.frame.minY + local.y
            ),
            windowPointFromTop: local,
            observedIn        : observation
        )
    }

    @Test("unchanged geometry preserves the point")
    func unchangedGeometry() throws {
        let observed = try Self.observation()
        let current  = try Self.observation(sequence: 2)
        let validated = try WindowCoordinateValidator.validate(
            .click(Self.location(in: observed)),
            against: current
        )

        guard case .click(let location, _, _) = validated else {
            Issue.record("Expected a click")
            return
        }
        #expect(location.screenPoint == CGPoint(x: 140, y: 260))
        #expect(location.observedGeometry == current)
    }

    @Test("a pure translation recalculates every point before construction")
    func pureTranslation() throws {
        let observed = try Self.observation()
        let current = try Self.observation(
            frame   : CGRect(x: 700, y: 900, width: 400, height: 300),
            sequence: 2
        )
        let validated = try WindowCoordinateValidator.validate(
            .drag(points: [
                Self.location(in: observed, local: CGPoint(x: 10, y: 20)),
                Self.location(in: observed, local: CGPoint(x: 30, y: 40)),
                Self.location(in: observed, local: CGPoint(x: 50, y: 60)),
            ]),
            against: current
        )

        guard case .drag(let points, _) = validated else {
            Issue.record("Expected a drag")
            return
        }
        #expect(points.map(\.screenPoint) == [
            CGPoint(x: 710, y: 920),
            CGPoint(x: 730, y: 940),
            CGPoint(x: 750, y: 960),
        ])
        #expect(points.allSatisfy { $0.observedGeometry == current })
    }

    @Test("translation preserves a repeated click's button and count")
    func repeatedClickTranslation() throws {
        let observed = try Self.observation()
        let current = try Self.observation(
            frame: CGRect(x: 700, y: 900, width: 400, height: 300),
            sequence: 2
        )
        let command = try WindowCoordinateValidator.validate(
            .click(Self.location(in: observed), button: .right, count: 3),
            against: current
        )
        guard case .click(let location, let button, let count) = command else {
            Issue.record("Expected a click")
            return
        }
        #expect(count == 3)
        #expect(button == .right)
        #expect(location.screenPoint == CGPoint(x: 740, y: 960))
        #expect(location.observedGeometry == current)
    }

    @Test("a translation after event construction is refused before posting")
    func lateTranslationIsRefused() throws {
        let constructed = try Self.observation(sequence: 2)
        let moved = try Self.observation(
            frame   : CGRect(x: 101, y: 200, width: 400, height: 300),
            sequence: 3
        )

        #expect(throws: InputFailure.coordinateGeometryChanged(
            observed: constructed.window.frame,
            current : moved.window.frame
        )) {
            try WindowCoordinateValidator.requireUnchanged(constructed, current: moved)
        }
    }

    @Test("late identity and scale changes are refused before posting")
    func lateIdentityAndScaleChangesAreRefused() throws {
        let constructed = try Self.observation(sequence: 2)
        let replacementIdentity = WindowIdentity(
            process: ProcessIdentity(
                processID       : 42,
                serialNumberHigh: 3,
                serialNumberLow : 6
            ),
            windowNumber     : 117,
            ownerConnectionID: 20
        )
        let replaced = try Self.observation(identity: replacementIdentity, sequence: 3)
        let rescaled = try Self.observation(scaleFactor: 1, sequence: 3)

        #expect(throws: InputFailure.self) {
            try WindowCoordinateValidator.requireUnchanged(constructed, current: replaced)
        }
        #expect(throws: InputFailure.coordinateScaleChanged(observed: 2, current: 1)) {
            try WindowCoordinateValidator.requireUnchanged(constructed, current: rescaled)
        }
    }

    @Test("legacy raw coordinates are refused")
    func missingObservation() throws {
        let raw = InputLocation(
            screenPoint       : CGPoint(x: 140, y: 260),
            windowPointFromTop: CGPoint(x: 40, y: 60)
        )

        #expect(throws: InputFailure.coordinateObservationMissing) {
            try WindowCoordinateValidator.validate(.click(raw), against: try Self.observation())
        }
    }

    @Test("resize requires a fresh observation")
    func resizeIsRefused() throws {
        let observed = try Self.observation()
        let resized = try Self.observation(
            frame   : CGRect(x: 100, y: 200, width: 500, height: 300),
            sequence: 2
        )

        #expect(throws: InputFailure.self) {
            try WindowCoordinateValidator.validate(
                .click(Self.location(in: observed)),
                against: resized
            )
        }
    }

    @Test("a display scale change requires a fresh observation")
    func scaleChangeIsRefused() throws {
        let observed = try Self.observation()
        let scaled   = try Self.observation(scaleFactor: 1, sequence: 2)

        #expect(throws: InputFailure.coordinateScaleChanged(observed: 2, current: 1)) {
            try WindowCoordinateValidator.validate(
                .click(Self.location(in: observed)),
                against: scaled
            )
        }
    }

    @Test("a different process lifetime or owner connection is refused")
    func identityChangeIsRefused() throws {
        let replacement = WindowIdentity(
            process: ProcessIdentity(
                processID       : 42,
                serialNumberHigh: 3,
                serialNumberLow : 6
            ),
            windowNumber     : 117,
            ownerConnectionID: 20
        )
        let observed = try Self.observation()
        let current  = try Self.observation(identity: replacement, sequence: 2)

        #expect(throws: InputFailure.self) {
            try WindowCoordinateValidator.validate(
                .click(Self.location(in: observed)),
                against: current
            )
        }
    }

    @Test("inconsistent coordinate frames and out of bounds points are refused")
    func inconsistentPointsAreRefused() throws {
        let observed = try Self.observation()
        let mismatched = InputLocation(
            screenPoint       : CGPoint(x: 999, y: 999),
            windowPointFromTop: CGPoint(x: 40, y: 60),
            observedIn        : observed
        )
        let outside = Self.location(in: observed, local: CGPoint(x: 400, y: 60))

        #expect(throws: InputFailure.coordinateSpacesDisagree) {
            try WindowCoordinateValidator.validate(.click(mismatched), against: observed)
        }
        #expect(throws: InputFailure.self) {
            try WindowCoordinateValidator.validate(.click(outside), against: observed)
        }
    }
}
