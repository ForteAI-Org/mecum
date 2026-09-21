//
//  CaptureShapeStabilisationTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/09/2026.
//

import CoreGraphics
@testable import SeatCapture
import Testing

/// The shape rule on its own, and the fact that the Monitor has no second copy
/// of it. A consumer driving its own `SeatCaptureStream` asks this type the
/// same question the Monitor asks it, which is the whole reason it exists
/// rather than living inside `MonitorConfiguration`.
@Suite("When a running capture should be reshaped, and to what")
struct CaptureShapeStabilisationTests {

    /// The oracle, written out rather than called: a reading is followed when
    /// it repeats within two pixels and the running size does not.
    private static func settled(running: CGSize, reading: CGSize, previous: CGSize?) -> CGSize? {
        guard let previous else { return nil }
        let near: (CGSize, CGSize) -> Bool = { one, other in
            abs(one.width - other.width) <= 2 && abs(one.height - other.height) <= 2
        }
        guard near(previous, reading), !near(running, reading) else { return nil }
        guard reading.width.isFinite, reading.height.isFinite,
              reading.width >= 1, reading.height >= 1 else { return nil }
        return reading
    }

    static let running = CGSize(width: 1334, height: 949)

    @Test("the rule answers what an independent reading of it answers")
    func theRuleMatchesItsOracle() {
        let readings: [(CGSize, CGSize?)] = [
            // A settled shape sixteen pixels short: the black band.
            (CGSize(width: 1334, height: 933), CGSize(width: 1334, height: 933)),
            // A first reading, with nothing to agree with.
            (CGSize(width: 1334, height: 933), nil),
            // One pixel either way, which is two roundings and not a band.
            (CGSize(width: 1335, height: 949), CGSize(width: 1333, height: 950)),
            // The shape the stream is already running.
            (Self.running, Self.running),
            // Sizes no buffer could have.
            (CGSize(width: 0, height: 933), CGSize(width: 0, height: 933)),
            (CGSize(width: CGFloat.infinity, height: 933), CGSize(width: CGFloat.infinity, height: 933))
        ]
        for (reading, previous) in readings {
            #expect(
                CaptureShapeStabilisation.settledShape(
                    running: Self.running, reading: reading, previousReading: previous)
                    == Self.settled(running: Self.running, reading: reading, previous: previous),
                "reading \(reading) after \(String(describing: previous))"
            )
        }
    }

    @Test("a shape still moving is never followed, however many readings it takes")
    func aMovingShapeIsNeverFollowed() {
        // The 700 ms shrink of a window moved onto the Virtual Display, read
        // on consecutive heartbeats.
        let moving = [
            CGSize(width: 1291, height: 949), CGSize(width: 712, height: 523),
            CGSize(width: 340,  height: 400), CGSize(width: 136, height: 190)
        ]
        for (previous, reading) in zip(moving, moving.dropFirst()) {
            #expect(CaptureShapeStabilisation.settledShape(
                running: Self.running, reading: reading, previousReading: previous) == nil)
        }
        // And the moment it comes to rest, once.
        #expect(CaptureShapeStabilisation.settledShape(
            running: Self.running,
            reading: CGSize(width: 136, height: 190),
            previousReading: CGSize(width: 136, height: 190)
        ) == CGSize(width: 136, height: 190))
    }

    /// One definition. The Monitor's own answer is `following`, and what it
    /// adds to the rule is the ladder's rebasing and nothing else, so at the
    /// top rung the two answer the same size for every reading.
    @Test("the monitor follows the shape this rule settles on and no other")
    func theMonitorHasNoSecondCopyOfTheRule() {
        let asked = MonitorConfiguration(
            targetFrameRate: .sixty,
            output         : .fixed(Self.running)
        )
        #expect(MonitorConfiguration.contentPixelTolerance
            == CaptureShapeStabilisation.contentPixelTolerance)

        for reading in [
            CGSize(width: 1334, height: 933), CGSize(width: 1335, height: 949),
            Self.running, CGSize(width: 136, height: 190), CGSize(width: 0, height: 4)
        ] {
            let stabilised = CaptureShapeStabilisation.settledShape(
                running: asked.captureConfiguration(for: .standard).pixelSize,
                reading: reading,
                previousReading: reading
            )
            let followed = asked.following(
                contentPixelSize: reading, previousReading: reading, at: .standard)
            #expect(followed?.captureConfiguration(for: .standard).pixelSize == stabilised,
                    "reading \(reading)")
        }
    }
}
