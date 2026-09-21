//
//  MonitorShapeFollowTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 18/09/2026.
//

import CoreGraphics
import SeatCore
@testable import SeatCapture
import Testing

/// The decisions behind following the target's shape: what counts as settled,
/// what counts as a difference worth a reconfiguration, and whether the ladder
/// still composes with the size that was followed.
@Suite("What the monitor asks the stream for when the target changes shape")
struct MonitorShapeFollowTests {

    /// The preview the person watches at the backing size of a 667 by 474,5
    /// point view on a Retina screen, which is the 1334 by 949 of the run this
    /// ticket came from.
    static let asked = MonitorConfiguration(
        targetFrameRate: .sixty,
        output         : .backing(pointSize: CGSize(width: 667, height: 474.5), scale: 2)
    )

    /// What the capture fills once the target no longer has the shape the
    /// stream was started with: the same width, sixteen pixels of black down
    /// the bottom edge.
    static let filled = CGSize(width: 1334, height: 933)

    @Test("a settled difference asks for the shape the capture is filling")
    func aSettledDifferenceIsFollowed() throws {
        let followed = try #require(Self.asked.following(
            contentPixelSize: Self.filled,
            previousReading : Self.filled,
            at              : .standard
        ))

        #expect(followed.captureConfiguration(for: .standard).pixelSize == Self.filled)
        #expect(followed.targetFrameRate == .sixty)
    }

    @Test("one reading is not a settled shape")
    func oneReadingIsNotSettled() {
        #expect(Self.asked.following(
            contentPixelSize: Self.filled,
            previousReading : nil,
            at              : .standard
        ) == nil)
    }

    @Test("a shape still moving between two readings is not followed")
    func aMovingShapeIsNotFollowed() {
        // The 700 ms shrink of a window moved onto the Virtual Display, read on
        // two consecutive heartbeats: no two readings of it agree.
        #expect(Self.asked.following(
            contentPixelSize: CGSize(width: 136, height: 190),
            previousReading : CGSize(width: 712, height: 523),
            at              : .standard
        ) == nil)
    }

    @Test("a difference inside the tolerance is arithmetic and not a band")
    func aRoundingDifferenceIsNotFollowed() {
        let rounded = CGSize(width: 1334, height: 948)
        #expect(Self.asked.following(
            contentPixelSize: rounded,
            previousReading : rounded,
            at              : .standard
        ) == nil)
    }

    @Test("a rung change after a followed shape is a fraction of that shape")
    func aRungChangeKeepsTheFollowedShape() throws {
        let followed = try #require(Self.asked.following(
            contentPixelSize: Self.filled,
            previousReading : Self.filled,
            at              : .standard
        ))
        let degraded = MonitorQuality(
            frameRate      : .thirty,
            resolutionScale: MonitorQuality.halfResolution
        )

        #expect(followed.captureConfiguration(for: degraded).pixelSize
            == CGSize(width: 667, height: 467))
        // What it must not be: half of the size the consumer first asked for,
        // which is the stale shape coming back with the rung.
        #expect(Self.asked.captureConfiguration(for: degraded).pixelSize
            == CGSize(width: 667, height: 475))
    }

    @Test("a shape followed from a lower rung is recorded at the top rung")
    func aFollowFromALowerRungRebasesToTheTop() throws {
        let degraded = MonitorQuality(
            frameRate      : .thirty,
            resolutionScale: MonitorQuality.halfResolution
        )
        let filledAtHalf = CGSize(width: 667, height: 467)
        let followed = try #require(Self.asked.following(
            contentPixelSize: filledAtHalf,
            previousReading : filledAtHalf,
            at              : degraded
        ))

        #expect(followed.captureConfiguration(for: degraded).pixelSize == filledAtHalf)
        #expect(followed.output.pixelSize == CGSize(width: 1334, height: 934))
    }

    @Test("the reading is the part of the buffer the capture filled, in pixels")
    func contentPixelSizeIsTheFilledPart() throws {
        let geometry = MonitorLayerTests.geometry(
            content: CGRect(x: 0, y: 0, width: 667, height: 466.5),
            pixels : CGSize(width: 1334, height: 949),
            scale  : 2
        )

        #expect(geometry.contentPixelSize == CGSize(width: 1334, height: 933))
    }

    @Test("a geometry the transform rules refuse reads no shape at all")
    func anInvalidGeometryHasNoContentPixelSize() {
        let geometry = MonitorLayerTests.geometry(
            content: CGRect(x: 0, y: 0, width: 667, height: 466.5),
            pixels : CGSize(width: 0, height: 0),
            scale  : 2
        )

        #expect(geometry.contentPixelSize == nil)
    }
}
