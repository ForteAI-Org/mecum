//
//  TopologyBaseline.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import Darwin
import SeatCore

/// TopologyBaseline is the person's display arrangement as it was the instant
/// before the kit touched anything: which displays existed, where each of them
/// sat, and which one was main. Every geometric invariant of the Seat Host is
/// asked of this value, and every restore is measured against it.
///
/// It is a **value**, immutable and `Sendable`, deliberately. Held instead as
/// mutable properties of the class that owns the virtual display, the same facts
/// force the watchdog, the teardown and the seat guard to reach through that
/// object and to run only where it lives. Here the baseline
/// outlives the display it was taken for, can be compared from anywhere, and
/// its predicates are unit testable against synthetic geometries that no Mac
/// has.
nonisolated public struct TopologyBaseline: Sendable, Equatable {

    /// The main display when the baseline was taken. It is the anchor of the
    /// whole coordinate space: its origin is `(0, 0)` by definition, and the
    /// kit failing to keep it main is a User Seat violation, not a detail.
    public let mainDisplayID: CGDirectDisplayID

    /// The person's displays and the bounds each of them had.
    public let physicalDisplays: [PhysicalDisplay]

    public init(mainDisplayID: CGDirectDisplayID, physicalDisplays: [PhysicalDisplay]) {
        self.mainDisplayID    = mainDisplayID
        self.physicalDisplays = physicalDisplays
    }

    /// Reads the machine now. It is taken from `CGGetActiveDisplayList` and not
    /// from `NSScreen.screens` for two reasons: the answer must not depend on
    /// AppKit having refreshed itself, and this value has to be usable off the
    /// main actor.
    ///
    /// It must be called **before** the virtual display exists, which is why
    /// `VirtualDisplay.create` takes it first: afterwards the active list would
    /// contain the kit's own display and the baseline would include it.
    public static func capture() throws -> TopologyBaseline {
        let displayIDs = try DisplayList.active()
        let displays   = displayIDs.map {
            PhysicalDisplay(displayID: $0, bounds: CGDisplayBounds($0))
        }
        guard !displays.isEmpty else { throw DisplayFailure.noPhysicalDisplays }
        return TopologyBaseline(mainDisplayID: CGMainDisplayID(), physicalDisplays: displays)
    }

    // MARK: Invariants

    /// Whether every display of the baseline still has the bounds it had.
    public var physicalTopologyUnchanged: Bool {
        physicalDisplays.allSatisfy {
            rectanglesMatch($0.bounds, $0.currentBounds)
        }
    }

    /// The two invariants a seat cannot run without: the person's main display
    /// is still main, and none of their displays moved or was resized.
    public func verify() throws {
        let currentMainDisplayID = CGMainDisplayID()
        guard currentMainDisplayID == mainDisplayID else {
            throw DisplayFailure.mainDisplayChanged(
                expected: mainDisplayID,
                actual  : currentMainDisplayID
            )
        }
        guard physicalTopologyUnchanged else {
            let moved = physicalDisplays.first {
                !rectanglesMatch($0.bounds, $0.currentBounds)
            }?.displayID ?? mainDisplayID
            throw DisplayFailure.physicalDisplayMoved(moved)
        }
    }

    // MARK: Geometry

    /// The union of the person's pixels at baseline time.
    public var physicalUnion: CGRect {
        physicalDisplays.reduce(CGRect.null) { $0.union($1.bounds) }
    }

    /// Where a virtual display of `pixelSize` is attached: the bottom right
    /// corner of the person's arrangement, touching it at a single point.
    ///
    /// A single point of contact is the design. The window server needs the
    /// displays to be adjacent, and any edge longer than a point is a corridor
    /// the pointer can walk through; the HID fence decides whether it may, but
    /// the geometry should not hand it a door in the first place.
    public func cornerAttachedOrigin() throws -> CGPoint {
        let union  = physicalUnion
        let origin = CGPoint(
            x: union.maxX.rounded(.up),
            y: (union.maxY - 1).rounded(.down)
        )
        guard origin.x >= CGFloat(Int32.min), origin.x <= CGFloat(Int32.max),
              origin.y >= CGFloat(Int32.min), origin.y <= CGFloat(Int32.max)
        else {
            throw DisplayFailure.originOutOfRange(origin)
        }
        return origin
    }

    /// How many square points of the virtual display sit on top of one of the
    /// person's. Anything but zero means the window server put the two
    /// surfaces in the same pixels, and the seat refuses.
    public func overlapArea(with virtualBounds: CGRect) -> CGFloat {
        physicalDisplays.reduce(0) { partial, display in
            let intersection = display.bounds.intersection(virtualBounds)
            guard !intersection.isNull else { return partial }
            return partial + intersection.width * intersection.height
        }
    }

    /// The longest shared edge between the virtual display and any of the
    /// person's, in points. The corner attachment asks for a single point, so
    /// anything wider is the window server having widened the door.
    public func maximumPortalLength(with virtualBounds: CGRect) -> CGFloat {
        physicalDisplays.reduce(0) { maximum, display in
            let physical = display.bounds
            var portal: CGFloat = 0
            if abs(physical.maxX - virtualBounds.minX) < 0.5
                || abs(virtualBounds.maxX - physical.minX) < 0.5 {
                portal = max(portal, max(
                    0,
                    min(physical.maxY, virtualBounds.maxY) - max(physical.minY, virtualBounds.minY)
                ))
            }
            if abs(physical.maxY - virtualBounds.minY) < 0.5
                || abs(virtualBounds.maxY - physical.minY) < 0.5 {
                portal = max(portal, max(
                    0,
                    min(physical.maxX, virtualBounds.maxX) - max(physical.minX, virtualBounds.minX)
                ))
            }
            return max(maximum, portal)
        }
    }

    /// The point on one of the person's displays closest to the virtual
    /// surface. It exists so a probe can aim at the boundary on purpose and
    /// measure that the fence held; nothing in the acting path uses it.
    public func boundaryProbePoint(nearest virtualBounds: CGRect) -> CGPoint {
        let reference = virtualBounds.origin
        return physicalDisplays.map { display in
            let maximumX = max(display.bounds.minX, display.bounds.maxX - 1)
            let maximumY = max(display.bounds.minY, display.bounds.maxY - 1)
            return CGPoint(
                x: min(max(reference.x, display.bounds.minX), maximumX),
                y: min(max(reference.y, display.bounds.minY), maximumY)
            )
        }.min {
            hypot($0.x - reference.x, $0.y - reference.y)
                < hypot($1.x - reference.x, $1.y - reference.y)
        } ?? .zero
    }

    // MARK: Writing the topology

    /// Attaches the virtual display to the corner and re-pins every physical
    /// origin in the **same** transaction.
    ///
    /// The order inside the transaction matters: the virtual display is placed
    /// first, so restoring the physical origins never has to pass through an
    /// arrangement where two displays overlap. The physical writes are not
    /// redundant either: the window server reflows the arrangement when a
    /// display appears, and writing the baseline origins back in the same
    /// commit is what keeps the person's screens where they were.
    public func attach(
        virtualDisplayID: CGDirectDisplayID,
        at origin       : CGPoint
    ) throws {

        try withTransaction { configuration in
            let virtualError = CGConfigureDisplayOrigin(
                configuration,
                virtualDisplayID,
                Int32(origin.x),
                Int32(origin.y)
            )
            guard virtualError == .success else {
                throw DisplayFailure.topologyConfigurationFailed(
                    step: .placeVirtualDisplay,
                    code: virtualError
                )
            }
            for display in physicalDisplays {
                let target = display.displayID == mainDisplayID
                    ? CGPoint.zero
                    : display.bounds.origin
                let error = CGConfigureDisplayOrigin(
                    configuration,
                    display.displayID,
                    Int32(target.x),
                    Int32(target.y)
                )
                guard error == .success else {
                    throw DisplayFailure.topologyConfigurationFailed(
                        step: .placePhysicalDisplay(display.displayID),
                        code: error
                    )
                }
            }
        }

        let mainAfterCommit = CGMainDisplayID()
        guard mainAfterCommit == mainDisplayID else {
            throw DisplayFailure.mainDisplayChanged(
                expected: mainDisplayID,
                actual  : mainAfterCommit
            )
        }
    }

    /// What a restore would do, given a display set and a main display, without
    /// touching anything.
    ///
    /// It is separated from the write for one reason: this is the decision that
    /// has to be right, and it is the only part of the restore that can be
    /// asked about a topology no Mac in the room has. The set is compared with
    /// `PhysicalDisplayRecoveryPolicy`: same display ids, same sizes, baseline
    /// main still at the origin. A hot plug, an unplug or a resolution change
    /// all fail that comparison, and the honest answer there is
    /// `topologyChangedByUser`, because writing the old origins back over a
    /// desk the person just rearranged would be the kit deciding for them.
    ///
    /// `restored` here means "a write is needed and allowed", which is what the
    /// same case means as `restore`'s return value once the write has happened.
    public func restoration(
        forCurrentDisplays current: [CGDirectDisplayID: CGRect],
        mainDisplayID currentMain : CGDirectDisplayID
    ) -> TopologyRestoration {

        let baseline = Dictionary(
            uniqueKeysWithValues: physicalDisplays.map { ($0.displayID, $0.bounds) }
        )
        guard PhysicalDisplayRecoveryPolicy.canRestore(
            baseline     : baseline,
            current      : current,
            mainDisplayID: mainDisplayID
        ) else {
            return .topologyChangedByUser
        }
        let unchanged = currentMain == mainDisplayID
            && baseline.allSatisfy { rectanglesMatch($0.value, current[$0.key]) }
        return unchanged ? .notNeeded : .restored
    }

    /// Puts the person's displays back where they were, or reports that they
    /// are no longer the same displays and touches nothing. The decision is
    /// `restoration(forCurrentDisplays:mainDisplayID:)`; this reads the machine
    /// and performs the write.
    @discardableResult
    public func restore() throws -> TopologyRestoration {

        let currentIDs = try DisplayList.active()
        let current    = Dictionary(
            uniqueKeysWithValues: currentIDs.map { ($0, CGDisplayBounds($0)) }
        )
        let decision = restoration(
            forCurrentDisplays: current,
            mainDisplayID     : CGMainDisplayID()
        )
        guard decision == .restored else { return decision }

        try withTransaction { configuration in
            // The auxiliaries move first and the original main last: the main
            // display defines the origin, so moving it while another display
            // still claims (0, 0) is the one ordering that can leave the
            // arrangement overlapping mid transaction.
            let ordered = physicalDisplays.filter { $0.displayID != mainDisplayID }
                + physicalDisplays.filter { $0.displayID == mainDisplayID }
            for display in ordered {
                let error = CGConfigureDisplayOrigin(
                    configuration,
                    display.displayID,
                    Int32(display.bounds.minX),
                    Int32(display.bounds.minY)
                )
                guard error == .success else {
                    throw DisplayFailure.topologyConfigurationFailed(
                        step: .placePhysicalDisplay(display.displayID),
                        code: error
                    )
                }
            }
        }
        return .restored
    }

    /// Opens a display configuration transaction, runs `body`, and commits it.
    /// A transaction that is not committed is cancelled, including on a thrown
    /// error: leaving one open would hold the window server's configuration
    /// lock for the rest of the process.
    private func withTransaction(_ body: (CGDisplayConfigRef) throws -> Void) throws {
        var configuration: CGDisplayConfigRef?
        let beginError = CGBeginDisplayConfiguration(&configuration)
        guard beginError == .success, let configuration else {
            throw DisplayFailure.topologyConfigurationFailed(
                step: .openTransaction,
                code: beginError
            )
        }
        var committed = false
        defer { if !committed { CGCancelDisplayConfiguration(configuration) } }

        try body(configuration)

        let completeError = CGCompleteDisplayConfiguration(configuration, .forSession)
        guard completeError == .success else {
            throw DisplayFailure.topologyConfigurationFailed(
                step: .commitTransaction,
                code: completeError
            )
        }
        committed = true
    }
}
