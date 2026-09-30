//
//  AssignmentFixtures.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics
@testable import SeatCore

/// Synthetic values for the assignment suites. Nothing here opens a window,
/// creates a Virtual Display, actuates focus or posts input: every reading, every
/// display and every clock value is written down here and handed to the same
/// Sources logic the kit composes.
///
/// A reading built with `qualifiedSurfaceEnumeration` exercises the algorithm
/// that runs when an enumerator has been qualified. It does not certify that any
/// such enumerator exists: no adapter on this build produces that provenance.
enum AssignmentFixtures {

    static let virtual  = CGRect(x: 4_000, y: 0, width: 1_920, height: 1_080)
    static let physical = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
    static let laptop   = CGRect(x: 1_920, y: 0, width: 1_280, height: 800)

    static let physicalDisplayID: CGDirectDisplayID = 1
    static let laptopDisplayID  : CGDirectDisplayID = 2

    static let displays: [CGDirectDisplayID: CGRect] = [
        physicalDisplayID: physical,
        laptopDisplayID  : laptop,
    ]

    /// A window frame on the person's display, and the frame the seat computes
    /// for it inside the Virtual Display.
    static let outside  = CGRect(x: 100, y: 100, width: 800, height: 600)
    static let contained = CGRect(x: 4_560, y: 240, width: 800, height: 600)

    /// The same window returned to the laptop, when the consumer chooses it.
    static let onLaptop = CGRect(x: 2_160, y: 100, width: 800, height: 600)

    static func process(_ processID: Int32, lifetime: UInt32 = 1) -> ProcessIdentity {
        ProcessIdentity(
            processID       : processID,
            serialNumberHigh: lifetime,
            serialNumberLow : UInt32(bitPattern: processID)
        )
    }

    /// The assigned instance, and the same PID after a restart.
    static let target   = process(501)
    static let restart  = process(501, lifetime: 2)
    static let helper   = process(777)
    static let stranger = process(902)

    static func identity(_ windowNumber: Int, of owner: ProcessIdentity = target) -> WindowIdentity {
        WindowIdentity(
            process          : owner,
            windowNumber     : windowNumber,
            ownerConnectionID: owner.processID &+ 1_000
        )
    }

    static func surface(
        _ windowNumber: Int,
        at frame      : CGRect,
        of owner      : ProcessIdentity = target,
        level         : Int  = 0,
        isVisible     : Bool = true
    ) -> WindowSurface {

        WindowSurface(
            reference: WindowReference(identity: identity(windowNumber, of: owner), frame: frame),
            level    : level,
            isVisible: isVisible
        )
    }

    static func row(
        _ windowNumber: Int,
        at frame      : CGRect,
        of owner      : ProcessIdentity = target,
        provenance    : EvidenceProvenance = .windowServerAttestedIdentity,
        isOrderedOut  : Bool = false
    ) -> SurfaceInventoryReading.Row {

        SurfaceInventoryReading.Row(
            surface     : surface(windowNumber, at: frame, of: owner),
            provenance  : provenance,
            isOrderedOut: isOrderedOut
        )
    }

    /// A row whose identity is carried by an unverified compatibility reference:
    /// a PID and a Window ID, which cannot attribute anything.
    static func unattestedRow(_ windowNumber: Int, at frame: CGRect) -> SurfaceInventoryReading.Row {
        SurfaceInventoryReading.Row(
            surface: WindowSurface(
                reference: WindowReference(
                    processID   : target.processID,
                    windowNumber: windowNumber,
                    frame       : frame
                ),
                level    : 0,
                isVisible: true
            ),
            provenance: .processIdentifier
        )
    }

    static func reading(
        _ rows      : [SurfaceInventoryReading.Row],
        completeness: InventoryCompleteness = .complete(provenance: .qualifiedSurfaceEnumeration)
    ) -> SurfaceInventoryReading {
        SurfaceInventoryReading(rows: rows, completeness: completeness)
    }
}

/// RecordingSurfaceEffector is a controlled adapter that preserves the contract
/// the real one has to: it records what was asked, refuses what an adapter must
/// refuse, and answers delivery rather than placement.
///
/// It moves nothing. The suites decide where the window is next by writing the
/// next reading, which is how the verification of an effect stays a reading and
/// not the absence of an error.
final class RecordingSurfaceEffector: SurfaceEffecting {

    struct Request: Equatable {
        let identity: WindowIdentity
        let frame   : CGRect
    }

    private(set) var requests: [Request] = []

    let qualification: EffectorQualification

    /// Refusals to answer for named Window IDs, so a suite can exercise a
    /// partial effect: some surfaces moved, one refused.
    var refusals: [Int: EffectRefusal]

    init(
        qualification: EffectorQualification = .qualified(primitive: "controlled test double"),
        refusals     : [Int: EffectRefusal] = [:]
    ) {
        self.qualification = qualification
        self.refusals      = refusals
    }

    var requestedWindowNumbers: [Int] { requests.map(\.identity.windowNumber) }

    func requestMove(of identity: WindowIdentity, to frame: CGRect) -> EffectDelivery {

        requests.append(Request(identity: identity, frame: frame))

        guard qualification.mayAct else {
            return .refused(.adapterNotQualified(reason: "The double was composed unqualified"))
        }
        if let refusal = refusals[identity.windowNumber] { return .refused(refusal) }
        guard identity.process.serialNumberHigh != 0 else { return .refused(.identityNotAttested) }
        guard rectangleIsUsable(frame) else {
            return .refused(.destinationUnusable(reason: "The destination is not a usable rectangle"))
        }
        return .issued
    }
}
