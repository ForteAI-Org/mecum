//
//  ApplicationTargetTransitionFilter.swift
//  AgentSeatKit
//
//  Created by OpenAI Codex on 16/09/2026.
//

import Foundation
import SeatCore

/// Turns the current AX main/focused-window state into edge-triggered recency.
///
/// The native cross-check is a snapshot, while `RecencyClaim` represents an
/// event. Re-emitting the same current window on every poll would incorrectly
/// cancel an explicit selection. This filter remembers only qualified complete
/// snapshots and emits the three accepted events: first appearance, established
/// reappearance, and a change in the application's current window.
nonisolated package final class ApplicationTargetTransitionFilter: @unchecked Sendable {

    /// How long a surface must stay outside the application's own window scope
    /// before its absence is the application's statement rather than a slow
    /// accessibility reading. A whole second is far longer than the bounded
    /// reads this reader makes, and it costs nothing but the wait: the surface
    /// keeps blocking exactly as it did before, for one more second.
    package static let withdrawalGraceNanoseconds: UInt64 = 1_000_000_000

    private let lock = NSLock()
    private var current: WindowIdentity?
    private var visibilities: [WindowIdentity: SurfaceVisibility] = [:]
    private var qualifiedIdentities: Set<WindowIdentity> = []
    private var withdrawnSince: [WindowIdentity: UInt64] = [:]

    package init() {}

    /// Identities from the last qualified native snapshot that still belong to
    /// one of the assigned process lifetimes. They widen only the exact
    /// WindowServer lookup, never AX's positive application-window scope.
    package func retainedIdentities(ownedBy processIDs: Set<Int32>) -> Set<WindowIdentity> {
        lock.lock()
        defer { lock.unlock() }

        return qualifiedIdentities.filter { processIDs.contains($0.processID) }
    }

    package func filter(
        _ snapshot: AssignedSurfaceSnapshot,
        at now    : UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> AssignedSurfaceSnapshot {
        lock.lock()
        defer { lock.unlock() }

        let withdrawn = confirmedWithdrawals(snapshot.withdrawnByApplication, at: now)
        var claims = snapshot.claims
        guard snapshot.inventory.completeness.isQualified else {
            claims.recency = []
            return AssignedSurfaceSnapshot(
                inventory: snapshot.inventory,
                claims   : claims,
                withdrawnByApplication: withdrawn
            )
        }

        let reported = claims.recency.count == 1 ? claims.recency[0] : nil
        claims.recency = []

        let previousVisibilities = visibilities
        let identities = Set(snapshot.inventory.rows.compactMap(\.surface.reference.identity))
        qualifiedIdentities = identities
        visibilities = Dictionary(uniqueKeysWithValues: claims.visibilities.compactMap { claim in
            identities.contains(claim.surface) ? (claim.surface, claim.state) : nil
        })

        guard let reported else {
            current = nil
            return AssignedSurfaceSnapshot(
                inventory: snapshot.inventory,
                claims   : claims,
                withdrawnByApplication: withdrawn
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
            withdrawnByApplication: withdrawn
        )
    }

    /// Narrows what the cross-check saw to what has been that way long enough
    /// to act on, and stops retaining those surfaces.
    ///
    /// Dropping them from the retained set is half the answer and the closure a
    /// seat confirms is the other: a surface nobody retains is no longer looked
    /// up by identity, so it stops disqualifying every later reading, and the
    /// application's own scope is what said so.
    private func confirmedWithdrawals(
        _ reported: [WindowIdentity],
        at now    : UInt64
    ) -> [WindowIdentity] {

        let seen = Set(reported)
        withdrawnSince = withdrawnSince.filter { seen.contains($0.key) }

        var confirmed: [WindowIdentity] = []
        for identity in reported {
            let since = withdrawnSince[identity] ?? now
            withdrawnSince[identity] = since
            guard now &- since >= Self.withdrawalGraceNanoseconds else { continue }
            confirmed.append(identity)
            qualifiedIdentities.remove(identity)
        }
        return confirmed
    }
}
