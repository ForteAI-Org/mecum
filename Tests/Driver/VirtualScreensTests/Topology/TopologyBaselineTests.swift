//
//  TopologyBaselineTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import Testing
@testable import VirtualScreens

/// Synthetic arrangements: a laptop alone, a laptop with an external screen to
/// its right, a portrait screen above. None of them is the machine running the
/// tests, which is the point, because the geometry the kit has to get right is
/// the one nobody has in the room.
nonisolated enum SyntheticTopology {

    static let laptopID  : CGDirectDisplayID = 0x1000_0001
    static let externalID: CGDirectDisplayID = 0x1000_0002

    /// One 1512 by 982 display at the origin.
    static let laptop = TopologyBaseline(
        mainDisplayID   : laptopID,
        physicalDisplays: [
            PhysicalDisplay(displayID: laptopID, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982)),
        ]
    )

    /// The laptop with a 2560 by 1440 screen touching its right edge.
    static let laptopWithExternalRight = TopologyBaseline(
        mainDisplayID   : laptopID,
        physicalDisplays: [
            PhysicalDisplay(displayID: laptopID, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982)),
            PhysicalDisplay(displayID: externalID, bounds: CGRect(x: 1512, y: 0, width: 2560, height: 1440)),
        ]
    )

    static func bounds(of baseline: TopologyBaseline) -> [CGDirectDisplayID: CGRect] {
        Dictionary(uniqueKeysWithValues: baseline.physicalDisplays.map { ($0.displayID, $0.bounds) })
    }
}

@Suite("Topology geometry on synthetic arrangements")
struct TopologyBaselineGeometryTests {

    @Test("the union of one display is that display")
    func unionOfOne() {
        #expect(SyntheticTopology.laptop.physicalUnion == CGRect(x: 0, y: 0, width: 1512, height: 982))
    }

    @Test("the union spans every display")
    func unionOfTwo() {
        #expect(
            SyntheticTopology.laptopWithExternalRight.physicalUnion
                == CGRect(x: 0, y: 0, width: 4072, height: 1440)
        )
    }

    @Test("the corner origin is the bottom right of the union, one point up")
    func cornerOrigin() throws {
        // maxX of the union, and maxY minus one: the minus one is what turns an
        // edge into a single point of contact.
        #expect(try SyntheticTopology.laptop.cornerAttachedOrigin() == CGPoint(x: 1512, y: 981))
        #expect(
            try SyntheticTopology.laptopWithExternalRight.cornerAttachedOrigin()
                == CGPoint(x: 4072, y: 1439)
        )
    }

    @Test("a corner origin outside Int32 is refused rather than truncated")
    func cornerOriginOutOfRange() {
        let absurd = TopologyBaseline(
            mainDisplayID   : SyntheticTopology.laptopID,
            physicalDisplays: [
                PhysicalDisplay(
                    displayID: SyntheticTopology.laptopID,
                    bounds   : CGRect(x: 0, y: 0, width: 4_000_000_000, height: 100)
                ),
            ]
        )

        #expect(throws: DisplayFailure.originOutOfRange(CGPoint(x: 4_000_000_000, y: 99))) {
            try absurd.cornerAttachedOrigin()
        }
    }

    @Test("a display at the corner origin does not overlap the person's pixels")
    func cornerAttachmentDoesNotOverlap() throws {
        let baseline = SyntheticTopology.laptopWithExternalRight
        let origin   = try baseline.cornerAttachedOrigin()
        let virtual  = CGRect(origin: origin, size: CGSize(width: 2560, height: 1440))

        #expect(baseline.overlapArea(with: virtual) == 0)
    }

    @Test("an overlapping display is measured in square points")
    func overlapIsMeasured() {
        // Ten by twenty points inside the laptop's bounds.
        let virtual = CGRect(x: 1502, y: 962, width: 2560, height: 1440)

        #expect(SyntheticTopology.laptop.overlapArea(with: virtual) == 200)
    }

    @Test("the corner attachment leaves a portal of one point, not an edge")
    func portalIsAPoint() throws {
        let baseline = SyntheticTopology.laptop
        let origin   = try baseline.cornerAttachedOrigin()
        let virtual  = CGRect(origin: origin, size: CGSize(width: 2560, height: 1440))

        // The shared extent is the single point row at y = 981.
        #expect(baseline.maximumPortalLength(with: virtual) == 1)
    }

    @Test("a display sharing a whole edge reports the whole edge")
    func portalIsAnEdge() {
        // Flush against the laptop's right edge, same height: a 982 pt corridor.
        let virtual = CGRect(x: 1512, y: 0, width: 2560, height: 982)

        #expect(SyntheticTopology.laptop.maximumPortalLength(with: virtual) == 982)
    }

    @Test("the boundary probe point is on the person's display, nearest the virtual one")
    func boundaryProbePoint() throws {
        let baseline = SyntheticTopology.laptop
        let origin   = try baseline.cornerAttachedOrigin()
        let virtual  = CGRect(origin: origin, size: CGSize(width: 2560, height: 1440))
        let probe    = baseline.boundaryProbePoint(nearest: virtual)

        // Clamped to the last addressable pixel of the laptop, never onto the
        // virtual surface itself.
        #expect(probe == CGPoint(x: 1511, y: 981))
        #expect(baseline.physicalDisplays[0].bounds.contains(probe))
        #expect(!virtual.contains(probe))
    }

    @Test("a baseline of synthetic displays never reads as unchanged")
    func syntheticGeometryIsNotTheMachine() {
        // `CGDisplayBounds` answers a zero rectangle for an id no display has,
        // so the invariant is false and `verify` throws. This is the property
        // the watchdog leans on: a display that stopped existing does not read
        // as intact.
        #expect(!SyntheticTopology.laptop.physicalTopologyUnchanged)
        #expect(throws: DisplayFailure.self) {
            try SyntheticTopology.laptop.verify()
        }
    }

    /// Skipped while no display is awake: `CGGetActiveDisplayList` is empty on
    /// a Mac whose screen has gone to sleep, and a capture with no physical
    /// display throws by design. See `aDisplayIsAwake`.
    @Test("capturing the running machine gives a baseline that verifies",
          .enabled(if: aDisplayIsAwake()))
    func captureVerifies() throws {
        let baseline = try TopologyBaseline.capture()

        #expect(!baseline.physicalDisplays.isEmpty)
        #expect(baseline.mainDisplayID == CGMainDisplayID())
        #expect(baseline.physicalTopologyUnchanged)
        try baseline.verify()
    }
}

/// A screen connected after the baseline was taken. The baseline predates the
/// kit's own virtual display, so that display's id is in every active list the
/// seat reads and must never count as the person's new screen.
@Suite("A physical display added after the baseline")
struct PhysicalDisplayAddedTests {

    static let virtualID: CGDirectDisplayID = 0x2000_0001

    @Test("an id the baseline does not know is an added display")
    func addedIsDetected() {
        #expect(SyntheticTopology.laptop.physicalDisplayWasAdded(
            activeDisplayIDs: [SyntheticTopology.laptopID, Self.virtualID, SyntheticTopology.externalID],
            virtualDisplayID: Self.virtualID
        ))
    }

    @Test("the kit's own virtual display is not an added display")
    func virtualIsNotCounted() {
        #expect(!SyntheticTopology.laptop.physicalDisplayWasAdded(
            activeDisplayIDs: [SyntheticTopology.laptopID, Self.virtualID],
            virtualDisplayID: Self.virtualID
        ))
    }

    @Test("the same set of displays is unchanged")
    func sameSetIsUnchanged() {
        #expect(!SyntheticTopology.laptopWithExternalRight.physicalDisplayWasAdded(
            activeDisplayIDs: [SyntheticTopology.laptopID, SyntheticTopology.externalID],
            virtualDisplayID: Self.virtualID
        ))
    }

    /// Removal is the bounds check's to catch: the missing display reads as a
    /// zero rectangle there, and calling it "added" would name the wrong event.
    @Test("a removed display is not an added one")
    func removedIsNotAdded() {
        #expect(!SyntheticTopology.laptopWithExternalRight.physicalDisplayWasAdded(
            activeDisplayIDs: [SyntheticTopology.laptopID, Self.virtualID],
            virtualDisplayID: Self.virtualID
        ))
    }
}

@Suite("Deciding whether the person's topology may be restored")
struct TopologyRestorationDecisionTests {

    @Test("an untouched arrangement needs no restore")
    func untouched() {
        let baseline = SyntheticTopology.laptopWithExternalRight

        #expect(
            baseline.restoration(
                forCurrentDisplays: SyntheticTopology.bounds(of: baseline),
                mainDisplayID     : SyntheticTopology.laptopID
            ) == .notNeeded
        )
    }

    @Test("a moved auxiliary display is restored")
    func movedAuxiliary() {
        let baseline = SyntheticTopology.laptopWithExternalRight
        var current  = SyntheticTopology.bounds(of: baseline)
        current[SyntheticTopology.externalID] = CGRect(x: 1512, y: 500, width: 2560, height: 1440)

        #expect(
            baseline.restoration(forCurrentDisplays: current, mainDisplayID: SyntheticTopology.laptopID)
                == .restored
        )
    }

    @Test("a different main display is restored, not refused")
    func changedMainDisplay() {
        let baseline = SyntheticTopology.laptopWithExternalRight

        // Same displays, same sizes: the person did not touch their hardware,
        // the window server promoted the other screen. That is ours to undo.
        #expect(
            baseline.restoration(
                forCurrentDisplays: SyntheticTopology.bounds(of: baseline),
                mainDisplayID     : SyntheticTopology.externalID
            ) == .restored
        )
    }

    @Test("an unplugged display is the person's decision, and nothing is touched")
    func unplugged() {
        let baseline = SyntheticTopology.laptopWithExternalRight
        var current  = SyntheticTopology.bounds(of: baseline)
        current.removeValue(forKey: SyntheticTopology.externalID)

        #expect(
            baseline.restoration(forCurrentDisplays: current, mainDisplayID: SyntheticTopology.laptopID)
                == .topologyChangedByUser
        )
    }

    @Test("a newly plugged display is the person's decision too")
    func hotPlugged() {
        let baseline = SyntheticTopology.laptop
        var current  = SyntheticTopology.bounds(of: baseline)
        current[SyntheticTopology.externalID] = CGRect(x: 1512, y: 0, width: 2560, height: 1440)

        #expect(
            baseline.restoration(forCurrentDisplays: current, mainDisplayID: SyntheticTopology.laptopID)
                == .topologyChangedByUser
        )
    }

    @Test("a resolution change is the person's decision")
    func resolutionChanged() {
        let baseline = SyntheticTopology.laptopWithExternalRight
        var current  = SyntheticTopology.bounds(of: baseline)
        current[SyntheticTopology.externalID] = CGRect(x: 1512, y: 0, width: 1920, height: 1080)

        #expect(
            baseline.restoration(forCurrentDisplays: current, mainDisplayID: SyntheticTopology.laptopID)
                == .topologyChangedByUser
        )
    }

    @Test("a baseline whose main display was not at the origin cannot be restored")
    func baselineMainNotAtOrigin() {
        // The baseline itself is impossible: the main display defines the
        // origin. Restoring from it would write an arrangement that never was.
        let baseline = TopologyBaseline(
            mainDisplayID   : SyntheticTopology.laptopID,
            physicalDisplays: [
                PhysicalDisplay(
                    displayID: SyntheticTopology.laptopID,
                    bounds   : CGRect(x: 100, y: 100, width: 1512, height: 982)
                ),
            ]
        )

        #expect(
            baseline.restoration(
                forCurrentDisplays: SyntheticTopology.bounds(of: baseline),
                mainDisplayID     : SyntheticTopology.laptopID
            ) == .topologyChangedByUser
        )
    }

    @Test("an empty baseline restores nothing")
    func emptyBaseline() {
        let baseline = TopologyBaseline(mainDisplayID: 1, physicalDisplays: [])

        #expect(
            baseline.restoration(forCurrentDisplays: [:], mainDisplayID: 1)
                == .topologyChangedByUser
        )
    }
}
