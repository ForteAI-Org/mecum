//
//  WindowElementCache.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 17/09/2026.
//

import ApplicationServices
import CoreFoundation
import Foundation
import SeatCore

/// WindowElementCache remembers which accessibility element the relocator
/// resolved for an attested window, so that the next placement call on the same
/// window proves that element instead of searching for it again.
///
/// ## What it removes, and what it keeps
///
/// Resolving through `AXWindows` costs one round trip for the list plus one
/// `_AXUIElementGetWindow` per element until one matches, so a target with n
/// windows costs 1 + n at worst, and `move`, `resize`, `frame`, `fullScreen`,
/// `requestFullScreen`, `awaitFullScreen` and `stage` each pay it on every call.
/// A hit costs exactly one `_AXUIElementGetWindow`, on the remembered element.
///
/// The search is what goes; the check is not. Every hit is confirmed with the
/// same call the resolution itself uses, against the Window ID that was asked
/// for, so the relocator's rule that identity is re-established on every route
/// survives untouched. This is a stronger position than a cache whose key is
/// merely unlikely to collide: a hit that cannot prove its Window ID is not
/// used, it is dropped.
///
/// ## Why an unproven hit cannot slip through
///
/// A dead element fails the check rather than naming a second window:
/// `AppWindowWatch` measured `_AXUIElementGetWindow` answering -25201 on an
/// element whose window was destroyed, and this cache reads `nil` as stale.
/// The same is true of the two conditions the full resolution checks that a hit
/// skips, the Accessibility grant and the private symbol: without either, the
/// check cannot answer the expected number, so the entry is dropped and the
/// call falls into the full resolution and its existing refusal. A miss and a
/// stale hit are therefore indistinguishable from today's behaviour, failure
/// cases and associated values included.
///
/// ## The key
///
/// `WindowIdentity`, and never a Window ID or a PID alone: a PID reused after
/// its application terminated owns nothing this seat was driving, and a Window
/// ID WindowServer handed out again is a different window. An unattested
/// `WindowReference` has no identity to key on and is never cached at all.
///
/// ## The bound
///
/// Eight entries, which is more windows than a seat drives at once and small
/// enough that a session lasting hours cannot accumulate an entry per window it
/// ever touched. A ninth window empties the cache rather than evicting by age:
/// the cost of a wrong choice here is one full resolution, which is what every
/// call paid before this type existed, and an age-ordered structure is not
/// worth that.
///
/// One instance per placing witness, held by `SystemWindowPlacing` and
/// therefore scoped to one seat. `WindowRelocator` is a `nonisolated` enum of
/// statics, so a cache there would be both a data race and shared across every
/// seat in the process; the lock and the ownership follow
/// `AccessibilityWindowNumberCache`.
nonisolated public final class WindowElementCache: @unchecked Sendable {

    /// The most windows the cache carries. See the type's doc for the number.
    private static let capacity = 8

    private let lock = NSLock()
    private var entries: [WindowIdentity: AXUIElement] = [:]

    public init() {}

    /// How many windows the cache holds. The unit tier reads it to hold the
    /// cache to its bound.
    package var count: Int {
        lock.lock()
        defer { lock.unlock() }

        return entries.count
    }

    /// Answers the element for this window, either the remembered one whose
    /// Window ID `confirm` still reads back, or whatever `resolve` produces.
    ///
    /// `confirm` answering anything other than the identity's own Window ID,
    /// `nil` included, drops the entry before `resolve` runs, so a stale
    /// element never outlives the check that caught it even when the resolution
    /// after it throws.
    package func element(
        for identity       : WindowIdentity,
        confirmedBy confirm: (AXUIElement) -> Int?,
        otherwise resolve  : () throws -> AXUIElement
    ) rethrows -> AXUIElement {

        lock.lock()
        let cached = entries[identity]
        lock.unlock()

        // The check is a bounded accessibility round trip and runs outside the
        // lock: no placement call waits on another window's resolution.
        if let cached {
            if confirm(cached) == identity.windowNumber { return cached }
            lock.lock()
            entries[identity] = nil
            lock.unlock()
        }

        let resolved = try resolve()
        lock.lock()
        if entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
        entries[identity] = resolved
        lock.unlock()
        return resolved
    }

    /// Drops every entry, so the next call resolves exactly as an uncached one.
    package func removeAll() {
        lock.lock()
        defer { lock.unlock() }

        entries.removeAll()
    }
}
