//
//  CommandProvenance.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

import CoreGraphics
import SeatCore

/// CommandProvenance is the record of one Command pressed inside a brief
/// activation (ADR 0033): who the target is, which of its windows existed
/// before the press, when it was pressed and when the front went back.
///
/// It exists because the Command's effects arrive after the brief activation
/// ends. A native file panel opened by `File > Place Embedded...` is born on
/// the person's display and the application takes the front for it, and the
/// seat could not tell that activation from the person's own. The record says
/// what belongs to the Command, and nothing else: a window of another process,
/// a window the target already had, or one first seen after the margin is not
/// explained by it.
///
/// It is per Command and per brief activation. It is not the per-assignment
/// `SurfaceOrigin.bornDuringAssignment`, which says a window was born while the
/// application was assigned and nothing about which Command caused it.
///
/// A value, owned and mutated only by `UserFocusRecovery` on the main actor.
/// It moves nothing and posts nothing: it answers questions.
nonisolated struct CommandProvenance {

    /// How long after the handback the record still explains what the target
    /// does, in nanoseconds. Measured on 07/10/2026 with Photoshop's Place
    /// Embedded: the target retook the front 58 ms after a verified handback,
    /// the panel's window server row appeared 730 ms after it, and in another
    /// run the command's own activation notification arrived about 300 ms
    /// after it. 1.5 s is twice the longest of those, to be qualified live.
    static let marginNanoseconds: UInt64 = 1_500_000_000

    /// One window of the target first seen after the press.
    struct Sighting: Equatable {
        let identity          : WindowIdentity
        let level             : Int
        let firstSeen         : UInt64
        let isOnVirtualDisplay: Bool

        /// The one `.notice` line a new window of the target is worth.
        func line(pressedAt: UInt64) -> String {
            "a new window of the Command's target appeared: window \(identity.windowNumber), "
                + "process \(identity.processID), layer \(level), on "
                + (isOnVirtualDisplay ? "the virtual display" : "a physical display")
                + ", \((firstSeen &- pressedAt) / 1_000_000) ms after the press"
        }
    }

    /// The target, attested: a PID reused after a restart owns nothing here.
    let process: ProcessIdentity

    /// The person's window the front goes back to, as observed before the
    /// press.
    let person: WindowReference

    /// The target's on-screen window numbers read immediately before the press,
    /// nil when that reading failed. Without it nothing can be called new, so
    /// nothing is.
    let windowsBeforePress: Set<Int>?

    let pressedAt: UInt64

    /// When the handback finished, nil while the brief activation is running.
    private(set) var handbackAt: UInt64?

    /// The new windows of the target, by Window ID, in the order first seen.
    private(set) var sightings: [Int: Sighting] = [:]

    /// The sighted windows the seat has taken in.
    private(set) var adopted: Set<Int> = []

    /// Whether the one extra handback this record allows has been started.
    /// It is shared by every trigger, so two can never be made.
    var handbackRetried = false

    init(process: ProcessIdentity, person: WindowReference, windowsBeforePress: Set<Int>?, pressedAt: UInt64) {
        self.process            = process
        self.person             = person
        self.windowsBeforePress = windowsBeforePress
        self.pressedAt          = pressedAt
    }

    /// When the margin ends, nil while the brief activation is still running.
    var validUntil: UInt64? { handbackAt.map { $0 &+ Self.marginNanoseconds } }

    /// Whether the record explains the target's behaviour at `instant`.
    func covers(_ instant: UInt64) -> Bool {
        guard instant >= pressedAt else { return false }
        guard let end = validUntil else { return true }
        return instant < end
    }

    mutating func close(at instant: UInt64) {
        if handbackAt == nil { handbackAt = instant }
    }

    mutating func noteAdopted(_ windowNumber: Int) {
        if sightings[windowNumber] != nil { adopted.insert(windowNumber) }
    }

    /// Records the windows of the target that are new since the press and
    /// answers the ones seen for the first time now. A window of another
    /// process, one the reading before the press already listed, and anything
    /// first seen outside the record's validity are never sighted.
    mutating func sight(
        _ surfaces   : [WindowSurface],
        at instant   : UInt64,
        virtualBounds: CGRect
    ) -> [Sighting] {
        guard let before = windowsBeforePress, covers(instant) else { return [] }
        var fresh: [Sighting] = []
        for surface in surfaces {
            guard let identity = surface.reference.identity, identity.process == process,
                  !before.contains(identity.windowNumber),
                  sightings[identity.windowNumber] == nil
            else { continue }
            let sighting = Sighting(
                identity          : identity,
                level             : surface.level,
                firstSeen         : instant,
                isOnVirtualDisplay: virtualBounds.contains(surface.reference.frame)
            )
            sightings[identity.windowNumber] = sighting
            fresh.append(sighting)
        }
        return fresh
    }

    /// The sighting that stands behind `window`, nil when the Command does not
    /// explain it: its identity, process and Window ID must all be the ones
    /// first seen.
    func sighting(of window: WindowReference) -> Sighting? {
        guard let identity = window.identity, identity.process == process,
              let sighting = sightings[identity.windowNumber], sighting.identity == identity
        else { return nil }
        return sighting
    }
}
