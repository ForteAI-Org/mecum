//
//  VirtualDisplay.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import AppKit
import CoreGraphics
import Darwin
import Dispatch
import Foundation
import os
import PrivateSymbols

/// VirtualDisplay is the surface an Agent Seat lives on: a real display,
/// attached to a single point of the corner of the person's arrangement, backed
/// by the private `CGVirtualDisplay` classes.
///
/// Three facts about it are load bearing:
///
/// 1. **The display exists exactly as long as the private object does.** The
///    class has no removal selector: releasing the object is the mechanism, and
///    it works, taking 78 to 94 ms to leave `CGGetOnlineDisplayList` on
///    26A5425a. `invalidate()` drops that reference on
///    purpose so a fail-closed teardown does not depend on when this instance
///    is deallocated.
/// 2. **Publication is a two step affair.** CoreGraphics accepts the display
///    after `applySettings:`; the topology only accepts it after AppKit has
///    registered an `NSScreen` for it. The caller has to wait in between, which
///    is why `create` does not configure the topology itself. See
///    `ScreenRegistration`.
/// 3. **Whether the display went away is a list membership, never
///    `CGDisplayIsOnline`.** That call answers `0xFFFFFFFF` for an id that no
///    longer exists, so both spellings of the obvious idiom are wrong on the
///    case they were written for. See `DisplayList`, where the defect and the
///    three shapes of code it breaks are written down.
///
/// It is `@MainActor` by the target's default isolation rather than the `actor`
/// Spec section 7 asks for, and it waits for nothing: see
/// `Documentation/Driver/adr/Adr0007TheDisplayLifecycleIsCallerPumped.md`. Both
/// follow from the same measured fact, that a virtual display only makes
/// progress while the caller's application event loop turns.
public final class VirtualDisplay {

    private static let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "display")

    // MARK: Identity, readable from anywhere

    /// The display id the window server published. Immutable: the id does not
    /// survive the display, and a new display is a new instance.
    nonisolated public let displayID: CGDirectDisplayID

    /// The backing size in pixels, as asked for.
    nonisolated public let pixelSize: CGSize

    /// The name the person sees in System Settings.
    nonisolated public let name: String

    /// The person's arrangement as it was before this display existed. Every
    /// invariant and the restore are asked of this value, and it outlives the
    /// display so a teardown can still compare against it.
    nonisolated public let topology: TopologyBaseline

    /// The corner origin the display was asked to sit at.
    nonisolated public let requestedOrigin: CGPoint

    // MARK: Observations made while the display was set up

    /// Whether the display ever appeared in `CGGetActiveDisplayList`.
    /// Telemetry, not a gate: on 26A5425a a `CGVirtualDisplay` that has not
    /// been placed in the topology yet can legitimately be missing from it.
    public private(set) var appearedInActiveDisplayList = false

    /// Whether the person's main display lost that role at any point while the
    /// display was being created or attached. A seat does not start on a
    /// machine where that happened.
    public private(set) var mainChangedDuringCreation: Bool

    /// Whether `configureTopology` has already committed.
    public private(set) var isTopologyConfigured = false

    /// The private object. The display is alive while this is not nil.
    private var retained: NSObject?

    private init(
        retained                   : NSObject,
        displayID                  : CGDirectDisplayID,
        pixelSize                  : CGSize,
        name                       : String,
        topology                   : TopologyBaseline,
        requestedOrigin            : CGPoint,
        mainChangedDuringCreation  : Bool
    ) {
        self.retained                    = retained
        self.displayID                   = displayID
        self.pixelSize                   = pixelSize
        self.name                        = name
        self.topology                    = topology
        self.requestedOrigin             = requestedOrigin
        self.mainChangedDuringCreation   = mainChangedDuringCreation
    }

    // MARK: Live geometry

    /// The display's bounds in Quartz coordinates, read now.
    nonisolated public var quartzBounds: CGRect { CGDisplayBounds(displayID) }

    /// Whether the window server still lists this display. Throws when the
    /// enumeration fails, because a call that did not answer is not evidence
    /// the display went away.
    nonisolated public var isOnline: Bool {
        get throws { try DisplayList.isOnline(displayID) }
    }

    /// Whether CoreGraphics considers the display ready to draw on.
    ///
    /// Written `== 1` rather than `!= 0`, which is not pedantry: for a display
    /// id that does not exist these calls answer `0xFFFFFFFF`, so `!= 0` reads
    /// as "ready" for a display that was never published. A creation path with
    /// that test, from the second display in a process on, stops waiting
    /// immediately and reports a wait of zero: the wait is not happening at all.
    /// See `DisplayList` for the same defect in its other two spellings.
    ///
    /// The caller polls this, or better waits for `appKitScreen`, which implies
    /// it. Neither wait can be done for the caller: both need the application
    /// event loop to turn, and only the caller knows how it pumps events.
    nonisolated public var isRegistered: Bool {
        CGDisplayIsActive(displayID) == 1 && CGDisplayIsOnline(displayID) == 1
    }

    /// Square points of overlap between this display and the person's. Anything
    /// but zero and the seat refuses: the two surfaces would share pixels.
    nonisolated public var physicalOverlapArea: CGFloat {
        topology.overlapArea(with: quartzBounds)
    }

    /// The longest shared edge with one of the person's displays. The corner
    /// attachment asks for a point, so anything wider is a corridor the window
    /// server opened on its own.
    nonisolated public var maximumPhysicalPortalLength: CGFloat {
        topology.maximumPortalLength(with: quartzBounds)
    }

    /// The point on the person's displays nearest this surface, for a probe
    /// that wants to aim at the boundary on purpose.
    nonisolated public var physicalBoundaryProbePoint: CGPoint {
        topology.boundaryProbePoint(nearest: quartzBounds)
    }

    /// The `NSScreen` AppKit publishes for this display, if it has.
    public var appKitScreen: NSScreen? { ScreenRegistration.screen(for: displayID) }

    /// The two User Seat invariants, checked against the baseline.
    nonisolated public func verifyTopology() throws { try topology.verify() }

    // MARK: Creation

    /// The private primitives creating the surface needs.
    ///
    /// This is deliberately a **subset** of `Facility.display.requirements`,
    /// which also lists `_AXUIElementGetWindow` and the Accessibility grant.
    /// Those belong to `WindowRelocator`: refusing to create a display because
    /// the person has not granted Accessibility yet would report the wrong
    /// missing thing, and a Seat Host that wants to show a Monitor before it
    /// ever moves a window needs the surface and nothing else.
    nonisolated public static let surfacePrimitives: [PrimitiveRequirement] = [
        .objcClass(.virtualDisplay),
        .objcClass(.virtualDisplayDescriptor),
        .objcClass(.virtualDisplayMode),
        .objcClass(.virtualDisplaySettings),
        .selector(.initWithDescriptor),
        .selector(.applySettings),
        .selector(.initWithMode),
        .symbol(.messageSend),
    ]

    /// Builds the display and returns. It **waits for nothing**: neither for
    /// CoreGraphics to call the display active and online, nor for AppKit to
    /// publish an `NSScreen`, nor does it configure the topology.
    ///
    /// That is the decision of
    /// `Documentation/Driver/adr/Adr0007TheDisplayLifecycleIsCallerPumped.md`,
    /// and it is measured: a virtual
    /// display only makes progress while the caller's application event loop
    /// turns, so a wait here either blocks the thread that would have pumped,
    /// or suspends it and lets the concurrency runtime end the process. The
    /// caller waits, on `isRegistered` or better on `appKitScreen`, while
    /// pumping, and then calls `configureTopology`.
    ///
    /// The whole `CGVirtualDisplay*` family has no header, so every step here
    /// goes through `objc_msgSend` with a hand written ABI. That is the one
    /// place in this module where the type system stops helping, which is why
    /// every class and selector is a Ledger row checked before the first
    /// message is sent: a missing primitive is a `DisplayFailure`, not a trap.
    public static func create(
        _ configuration: VirtualDisplayConfiguration = VirtualDisplayConfiguration(),
        table          : SymbolTable = .shared
    ) throws -> VirtualDisplay {

        if let missing = table.firstUnresolved(of: surfacePrimitives) {
            throw DisplayFailure.primitiveUnavailable(missing)
        }
        guard
            let descriptorClass = table.objcClass(.virtualDisplayDescriptor) as? NSObject.Type,
            let settingsClass   = table.objcClass(.virtualDisplaySettings)   as? NSObject.Type,
            let displayClass    = table.objcClass(.virtualDisplay),
            let modeClass       = table.objcClass(.virtualDisplayMode),
            let sendAlloc       = table.function(.messageSend, as: MessageSendAlloc.self),
            let sendInitObject  = table.function(.messageSend, as: MessageSendInitWithObject.self),
            let sendInitMode    = table.function(.messageSend, as: MessageSendInitMode.self),
            let sendApply       = table.function(.messageSend, as: MessageSendApplySettings.self)
        else {
            throw DisplayFailure.primitiveUnavailable("CGVirtualDisplay")
        }

        let baseline = try TopologyBaseline.capture()
        let surface  = try makeSurface(
            configuration  : configuration,
            descriptorClass: descriptorClass,
            settingsClass  : settingsClass,
            displayClass   : displayClass,
            modeClass      : modeClass,
            sendAlloc      : sendAlloc,
            sendInitObject : sendInitObject,
            sendInitMode   : sendInitMode,
            sendApply      : sendApply
        )
        let origin = try baseline.cornerAttachedOrigin()

        log.info("""
            virtual display \(surface.displayID, privacy: .public) created, \
            \(configuration.pixelWidth, privacy: .public)x\
            \(configuration.pixelHeight, privacy: .public) at \
            \(configuration.refreshRate.rawValue, privacy: .public) Hz
            """)

        return VirtualDisplay(
            retained                   : surface.object,
            displayID                  : surface.displayID,
            pixelSize                  : configuration.pixelSize,
            name                       : VirtualDisplayConfiguration.displayName,
            topology                   : baseline,
            requestedOrigin            : origin,
            mainChangedDuringCreation  : surface.mainChanged
        )
    }

    /// The queue `CGVirtualDisplay` delivers its callbacks on, one for the
    /// process and never a fresh one per display.
    ///
    /// A queue per display is invisible while a process creates only one, and
    /// wrong the moment it creates two: with a per-display queue the **second**
    /// creation in a process never becomes active and online, `applySettings:`
    /// having published nothing (reproduced on 26A5425a,
    /// every cycle after the first). The framework outlives the descriptor and
    /// keeps using the queue it was given, so the queue has to outlive the
    /// display too.
    private static let callbackQueue = DispatchQueue(label: "dev.forte.AgentSeatKit.VirtualDisplay")

    /// What building the private objects yields: the object whose lifetime is
    /// the display, the id the window server published for it, and whether the
    /// person's main display changed while it was happening.
    private struct Surface {
        let object     : NSObject
        let displayID  : CGDirectDisplayID
        let mainChanged: Bool
    }

    /// Builds the private objects and hands back the one whose lifetime is the
    /// display.
    ///
    /// The whole construction runs inside **one autorelease pool**, and the
    /// display escapes it as a returned strong reference. Without the pool the
    /// bridging cast of the initialised object leaves an autoreleased reference
    /// on it, so `invalidate()` does not drop the last one and the display only
    /// goes away when the consumer's run loop next drains a pool: measured on
    /// 26A5425a as 328 ms instead of 34 to 94 ms, which is the difference
    /// between missing and meeting the 200 ms removal budget of spec section 8.
    private static func makeSurface(
        configuration  : VirtualDisplayConfiguration,
        descriptorClass: NSObject.Type,
        settingsClass  : NSObject.Type,
        displayClass   : AnyClass,
        modeClass      : AnyClass,
        sendAlloc      : MessageSendAlloc,
        sendInitObject : MessageSendInitWithObject,
        sendInitMode   : MessageSendInitMode,
        sendApply      : MessageSendApplySettings
    ) throws -> Surface {

        try autoreleasepool {
            let descriptor = descriptorClass.init()
            descriptor.setValue(VirtualDisplayConfiguration.vendorID,    forKey: "vendorID")
            descriptor.setValue(VirtualDisplayConfiguration.productID,   forKey: "productID")
            descriptor.setValue(VirtualDisplayConfiguration.serial,      forKey: "serialNum")
            descriptor.setValue(VirtualDisplayConfiguration.displayName, forKey: "name")
            descriptor.setValue(configuration.pixelWidth,  forKey: "maxPixelsWide")
            descriptor.setValue(configuration.pixelHeight, forKey: "maxPixelsHigh")
            descriptor.setValue(
                NSValue(size: VirtualDisplayConfiguration.sizeInMillimeters),
                forKey: "sizeInMillimeters"
            )
            // sRGB primaries and D65. The window server needs a colour space,
            // and an omitted one leaves the person with a display profile they
            // did not choose the next time macOS remembers this monitor.
            descriptor.setValue(NSValue(point: CGPoint(x: 0.6797, y: 0.3203)), forKey: "redPrimary")
            descriptor.setValue(NSValue(point: CGPoint(x: 0.2559, y: 0.6983)), forKey: "greenPrimary")
            descriptor.setValue(NSValue(point: CGPoint(x: 0.1494, y: 0.0557)), forKey: "bluePrimary")
            descriptor.setValue(NSValue(point: CGPoint(x: 0.3125, y: 0.3291)), forKey: "whitePoint")
            descriptor.setValue(callbackQueue, forKey: "queue")

            let mainBeforeCreation = CGMainDisplayID()

            let allocatedDisplay = sendAlloc(displayClass, NSSelectorFromString("alloc"))
            guard
                let initializedDisplay = sendInitObject(
                    allocatedDisplay.takeUnretainedValue(),
                    NSSelectorFromString("initWithDescriptor:"),
                    descriptor
                ),
                let display = initializedDisplay.takeRetainedValue() as? NSObject
            else {
                throw DisplayFailure.displayCreationFailed
            }

            let mainAfterCreation = CGMainDisplayID()

            let allocatedMode = sendAlloc(modeClass, NSSelectorFromString("alloc"))
            guard
                let initializedMode = sendInitMode(
                    allocatedMode.takeUnretainedValue(),
                    NSSelectorFromString("initWithWidth:height:refreshRate:"),
                    configuration.pixelWidth,
                    configuration.pixelHeight,
                    configuration.refreshRate.rawValue
                ),
                let mode = initializedMode.takeRetainedValue() as? NSObject
            else {
                throw DisplayFailure.modeRejected
            }

            let settings = settingsClass.init()
            settings.setValue(UInt32(0), forKey: "hiDPI")
            settings.setValue(UInt32(0), forKey: "rotation")
            settings.setValue([mode],    forKey: "modes")

            guard sendApply(display, NSSelectorFromString("applySettings:"), settings) else {
                throw DisplayFailure.settingsRejected
            }

            // The id the object carries before `applySettings:` is not
            // necessarily one the configuration API accepts yet, so it is read
            // afterwards.
            guard let number = display.value(forKey: "displayID") as? NSNumber,
                  number.uint32Value != 0
            else {
                throw DisplayFailure.displayIDUnavailable
            }
            return Surface(
                object     : display,
                displayID  : number.uint32Value,
                mainChanged: mainAfterCreation != mainBeforeCreation
            )
        }
    }

    // MARK: Topology

    /// Attaches the display to the corner of the person's arrangement, in one
    /// display configuration transaction that also re-pins every physical
    /// origin. It must be called after AppKit has published the `NSScreen`:
    /// before that, `CGConfigureDisplayOrigin` refuses the display.
    ///
    /// Calling it twice is not an error and not a second transaction: it
    /// re-verifies instead, which is what a caller retrying a setup wants.
    public func configureTopology() throws {
        guard !isTopologyConfigured else {
            try topology.verify()
            return
        }
        guard isRegistered else {
            throw DisplayFailure.notRegistered(
                displayID          : displayID,
                isActive           : CGDisplayIsActive(displayID) == 1,
                isOnline           : CGDisplayIsOnline(displayID) == 1,
                appearsInActiveList: (try? DisplayList.active().contains(displayID)) ?? false
            )
        }

        noteObservations()
        try topology.attach(virtualDisplayID: displayID, at: requestedOrigin)
        noteObservations()

        guard !mainChangedDuringCreation else {
            throw DisplayFailure.mainDisplayChanged(
                expected: topology.mainDisplayID,
                actual  : CGMainDisplayID()
            )
        }
        isTopologyConfigured = true
    }

    /// Puts the person's displays back, refusing while this display is still
    /// listed. The refusal is the point: the same guard written as
    /// `CGDisplayIsOnline(id) == 0` never becomes true, so it restores nothing
    /// on a machine whose topology is perfectly intact.
    @discardableResult
    public func restoreTopology() throws -> TopologyRestoration {
        guard try !isOnline else {
            throw DisplayFailure.displayStillOnline(displayID)
        }
        let outcome = try topology.restore()
        Self.log.info("topology restore: \(String(describing: outcome), privacy: .public)")
        return outcome
    }

    private func noteObservations() {
        mainChangedDuringCreation = mainChangedDuringCreation
            || CGMainDisplayID() != topology.mainDisplayID
        appearedInActiveDisplayList = appearedInActiveDisplayList
            || ((try? DisplayList.active().contains(displayID)) ?? false)
    }

    // MARK: Removal

    /// Drops the private object, which is what removes the display: the class
    /// has no removal selector, and releasing the last reference is the whole
    /// mechanism.
    ///
    /// It returns immediately, and the display is **not** gone yet. The window
    /// server stops listing it 36 to 97 ms later, and only while the caller's
    /// application event loop turns: a caller that releases the object and then
    /// blocks never sees the display leave (measured, and the reason there is
    /// no `remove()` that waits for you here). The pattern is
    ///
    ///     display.invalidate()
    ///     while try display.isOnline { pumpTheApplicationEventLoop() }
    ///     try display.restoreTopology()
    ///
    /// and `isOnline` is list membership, never `CGDisplayIsOnline`: see
    /// `DisplayList`. Idempotent, and safe from a synchronous teardown.
    public func invalidate() {
        retained = nil
    }

    // MARK: The hand written ABI of the private classes

    private typealias MessageSendAlloc = @convention(c) (
        AnyClass, Selector
    ) -> Unmanaged<AnyObject>

    private typealias MessageSendInitWithObject = @convention(c) (
        AnyObject, Selector, AnyObject
    ) -> Unmanaged<AnyObject>?

    private typealias MessageSendInitMode = @convention(c) (
        AnyObject, Selector, UInt32, UInt32, Double
    ) -> Unmanaged<AnyObject>?

    private typealias MessageSendApplySettings = @convention(c) (
        AnyObject, Selector, AnyObject
    ) -> Bool
}
