//
//  ApplicationTargetTransitionFilter.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation
import OSLog
import SeatCore

/// Turns the current AX main/focused-window state into edge-triggered recency.
///
/// The native cross-check is a snapshot, while `RecencyClaim` represents an
/// event. Re-emitting the same current window on every poll would incorrectly
/// cancel an explicit selection. This filter emits the three accepted events,
/// first appearance, established reappearance and a change in the application's
/// current window, from a qualified complete snapshot alone, and it remembers
/// what every pass attested so the next pass can look those identities up.
nonisolated package final class ApplicationTargetTransitionFilter: @unchecked Sendable {

    private static let observationLog = Logger(
        subsystem: "dev.forte.AgentSeatKit",
        category : "Observation"
    )

    /// How long a surface must stay outside the application's own window scope
    /// before its absence is the application's statement rather than a slow
    /// accessibility reading. A whole second is far longer than the bounded
    /// reads this reader makes, and it costs nothing but the wait: the surface
    /// keeps blocking exactly as it did before, for one more second.
    package static let withdrawalGraceNanoseconds: UInt64 = 1_000_000_000

    /// How long a window accessibility still lists may stay off screen and
    /// merely uncertain. A Space or Stage Manager transition is over well inside
    /// it; a Qt dialog closed by hiding it never is. Measured on DaVinci
    /// Resolve's "Change Project Frame Rate?": after its button, the window
    /// stayed in `AXWindows` with `AXModal` true and off screen for good, so as
    /// an uncertain modal it blocked the project window forever.
    package static let offScreenGraceNanoseconds: UInt64 = 2_000_000_000

    private let lock = NSLock()
    private var current: WindowIdentity?
    private var visibilities: [WindowIdentity: SurfaceVisibility] = [:]
    private var attestedIdentities: Set<WindowIdentity> = []
    private var withdrawnSince: [WindowIdentity: UInt64] = [:]
    private var offScreenSince: [WindowIdentity: UInt64] = [:]

    package init() {}

    /// Identities the last native pass attested that still belong to one of the
    /// assigned process lifetimes. They widen only the exact WindowServer
    /// lookup, never AX's positive application-window scope.
    package func retainedIdentities(ownedBy processIDs: Set<Int32>) -> Set<WindowIdentity> {
        lock.lock()
        defer { lock.unlock() }

        return attestedIdentities.filter { processIDs.contains($0.processID) }
    }

    /// Turns one native pass into the edge-triggered snapshot, and remembers
    /// what that pass attested so the next one can look it up by identity.
    ///
    /// Retention deliberately does not wait for an exact pass. A row of an
    /// inexact pass carries `windowServerAttestedIdentity` like any other and
    /// the assignment folds it in as a member either way, so a retention that
    /// skipped it would leave a member nothing ever names again: the window
    /// server is never asked about it, no answer can prove it destroyed, and it
    /// stays absent and uncertain until both containment budgets expire. The
    /// short-lived system surfaces macOS draws over a dialog live and die
    /// inside exactly such passes, which is how one of them suspended a seat
    /// for good.
    ///
    /// What leaves the retained set is positive as before: a destroyed identity
    /// at once, a withdrawn one when its grace has run out, and anything a
    /// qualified pass carries no row for. Nothing accumulates, because the set
    /// is one pass's rows plus the withdrawals that pass is still waiting on.
    ///
    /// **An unqualified pass drops nothing it says nothing about.** The
    /// on-screen fallback cannot list a window its application ordered out,
    /// and cannot be asked about it either. Measured on 30/09/2026 with
    /// Photoshop: its "Save changes?" alert, held by the seat, was hidden while
    /// the Save panel saved, the one pass taken then was the fallback, and
    /// the alert left this set. No later pass named it, so it stayed absent,
    /// its budget ran out at once and the seat was suspended for good.
    package func filter(
        _ snapshot: AssignedSurfaceSnapshot,
        at now    : UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> AssignedSurfaceSnapshot {
        lock.lock()
        defer { lock.unlock() }

        let previouslyAttested = attestedIdentities
        let retained      = graced(snapshot.retained, at: now)
        let withdrawn     = Set(retained.filter { $0.value == .withdrawn }.keys)
        let destroyed     = Set(retained.filter { $0.value == .destroyed }.keys)
        let rowIdentities = Set(snapshot.inventory.rows.compactMap(\.surface.reference.identity))

        // A destroyed window is looked up no more, and unlike a withdrawal it
        // waits for no grace: nothing brings a destroyed window back. An
        // ancestor kept under its child carries a row of its own, so it is
        // retained by the first term like every other surface of the pass.
        let unanswered = snapshot.inventory.completeness.isQualified ? [] : previouslyAttested
        attestedIdentities = rowIdentities
            .union(withdrawnSince.keys)
            .union(unanswered)
            .subtracting(withdrawn)
            .subtracting(destroyed)

        // Temporary live diagnosis for a short-lived adopted auxiliary surface:
        // the next native pass can only ask the WindowServer for an identity it
        // reaches through this set.  Log deltas, rather than every ordinary
        // reading, so a failed closure shows whether the loss is before or
        // after the transition filter.
        let admitted = attestedIdentities.subtracting(previouslyAttested)
        let omitted  = previouslyAttested.subtracting(attestedIdentities)
        if !admitted.isEmpty || !omitted.isEmpty || !retained.isEmpty {
            let rowNumbers      = String(describing: rowIdentities.map(\.windowNumber).sorted())
            let retainedNumbers = String(describing: retained.keys.map(\.windowNumber).sorted())
            let admittedNumbers = String(describing: admitted.map(\.windowNumber).sorted())
            let omittedNumbers  = String(describing: omitted.map(\.windowNumber).sorted())
            Self.observationLog.info(
                "[known-missing] filter qualified=\(snapshot.inventory.completeness.isQualified, privacy: .public) rows=\(rowNumbers, privacy: .public) retained=\(retainedNumbers, privacy: .public) admitted=\(admittedNumbers, privacy: .public) omitted=\(omittedNumbers, privacy: .public)"
            )
        }

        var claims = snapshot.claims
        guard snapshot.inventory.completeness.isQualified else {
            claims.recency = []
            return AssignedSurfaceSnapshot(
                inventory: snapshot.inventory,
                claims   : claims,
                retained : retained
            )
        }

        let reported = claims.recency.count == 1 ? claims.recency[0] : nil
        claims.recency = []
        claims.visibilities = settledOffScreen(claims.visibilities, rows: snapshot.inventory.rows, at: now)

        let previousVisibilities = visibilities
        visibilities = Dictionary(uniqueKeysWithValues: claims.visibilities.compactMap { claim in
            rowIdentities.contains(claim.surface) ? (claim.surface, claim.state) : nil
        })

        guard let reported else {
            current = nil
            return AssignedSurfaceSnapshot(
                inventory: snapshot.inventory,
                claims   : claims,
                retained : retained
            )
        }

        let previousCurrent = current
        current = reported.surface

        let signal: RecencySignal?
        switch previousVisibilities[reported.surface] {
            case .hiddenEstablished?, .minimisedEstablished?, .withdrawnEstablished?:
                signal = .reappeared
            case nil:
                signal = .appeared
            case .visibleInteractive?, .uncertain?:
                signal = previousCurrent == reported.surface ? nil : .returnedToFront
        }

        if let signal {
            claims.recency = [
                RecencyClaim(
                    surface              : reported.surface,
                    signal               : signal,
                    provenance           : reported.provenance,
                    origin               : reported.origin,
                    observedAtNanoseconds: reported.observedAtNanoseconds
                )
            ]
        }
        return AssignedSurfaceSnapshot(
            inventory: snapshot.inventory,
            claims   : claims,
            retained : retained
        )
    }

    /// Turns an uncertain visibility into an established withdrawal once the
    /// window server has shown the window off screen for the whole grace. Only
    /// that pairing: an uncertainty with the window on screen is a reading
    /// that decided nothing, and it keeps suspending as before.
    private func settledOffScreen(
        _ claims: [SurfaceVisibilityClaim],
        rows    : [SurfaceInventoryReading.Row],
        at now  : UInt64
    ) -> [SurfaceVisibilityClaim] {
        var offScreen: Set<WindowIdentity> = []
        for row in rows where !row.surface.isVisible {
            if let identity = row.surface.reference.identity { offScreen.insert(identity) }
        }
        let uncertain = Set(claims.filter { $0.state == .uncertain }.map(\.surface)).intersection(offScreen)
        offScreenSince = offScreenSince.filter { uncertain.contains($0.key) }
        return claims.map { claim in
            guard uncertain.contains(claim.surface) else { return claim }
            let since = offScreenSince[claim.surface] ?? now
            offScreenSince[claim.surface] = since
            guard now &- since >= Self.offScreenGraceNanoseconds else { return claim }
            return SurfaceVisibilityClaim(
                surface   : claim.surface,
                state     : .withdrawnEstablished,
                provenance: claim.provenance
            )
        }
    }

    /// Holds each withdrawal the cross-check reported inside its grace, where it
    /// reads as `temporarilyUnreadable`, and lets it through as a withdrawal
    /// once it has been that way long enough to act on. Every other disposition
    /// passes untouched: only this one is a question about elapsed time.
    ///
    /// Dropping a confirmed one from the retained set is half the answer and the
    /// closure a seat confirms is the other: a surface nobody retains is no
    /// longer looked up by identity, so it stops disqualifying every later
    /// reading, and the application's own scope is what said so. One still
    /// inside its grace is retained instead, because a grace nobody keeps asking
    /// about never ends.
    private func graced(
        _ reported: [WindowIdentity: RetainedSurfaceDisposition],
        at now    : UInt64
    ) -> [WindowIdentity: RetainedSurfaceDisposition] {

        let seen = Set(reported.filter { $0.value == .withdrawn }.keys)
        withdrawnSince = withdrawnSince.filter { seen.contains($0.key) }

        var graced = reported
        for identity in seen {
            let since = withdrawnSince[identity] ?? now
            withdrawnSince[identity] = since
            guard now &- since < Self.withdrawalGraceNanoseconds else { continue }
            graced[identity] = .temporarilyUnreadable
        }
        return graced
    }
}
