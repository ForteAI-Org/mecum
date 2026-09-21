//
//  AccessibilityWindowNumberCache.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 17/09/2026.
//

import ApplicationServices
import CoreFoundation
import Foundation

/// AccessibilityWindowNumberCache remembers the one fact the cross-checked pass
/// reads that cannot change while it is readable: the Window ID behind an
/// accessibility window element. Every other attribute that pass reads,
/// minimisation, modality, the main and focused window, and the two operability
/// traits of an unknown subrole, describes the moment and is read again.
///
/// ## Why the mapping cannot change
///
/// An accessibility window element is a handle on one window of one process.
/// WindowServer assigns that window its Window ID at creation and never
/// renumbers a live window, and the element is never re-pointed at a second
/// window: when its window dies the element goes invalid instead. `AppWindowWatch`
/// records what invalid answers, measured on the element an
/// `AXUIElementDestroyedNotification` carries: `_AXUIElementGetWindow` answers
/// -25201 and even AXRole fails. So an element that still answers answers the
/// same number, and the uncached call on a dead element fails rather than
/// naming a second window. The saved round trip is a repetition, not a guess.
///
/// ## What the key promises, and what it does not
///
/// The key is the process ID together with the element and never the process ID
/// alone, because a PID reused after its application terminated owns nothing
/// this seat was driving. `AXUIElement` is CF-equatable and CF-hashable, and two
/// separately created elements for the same target compare equal, which the unit
/// tier checks on application elements. That was **not** established for window
/// elements, whose element reference the target application supplies: an
/// application that recycles a destroyed window's reference could hand back a
/// key equal to a stored one for a window that is gone.
///
/// Correctness does not rest on that never happening. A stale entry names a
/// Window ID that WindowServer `.optionAll` will not attest for this process, so
/// the join marks the inventory incomplete and the seat fails closed exactly as
/// it does for any window without an attested counterpart. `SensingSurfaceReader`
/// empties this cache after every pass that did not qualify, which bounds a
/// stale reading to the one pass that already refused to act on it.
///
/// ## What the cache holds
///
/// Exactly the elements the last pass resolved. Each pass records what it
/// resolved and `endPass` makes that recording the whole cache, so a window that
/// closed and a process the seat stopped driving are both gone by the next pass,
/// and the cache cannot outgrow the windows the seat is currently driving.
///
/// One instance per reader, owned by `SensingSurfaceReader` and therefore scoped
/// to one seat. `CrossCheckedSurfaceReader` is a stateless nonisolated enum of
/// statics, so a static cache there would be a data race and process wide as
/// well; the lock and the ownership follow `ApplicationTargetTransitionFilter`.
nonisolated package final class AccessibilityWindowNumberCache: @unchecked Sendable {

    private struct Key: Hashable {
        let processID: Int32
        let element  : AXUIElement

        static func == (lhs: Key, rhs: Key) -> Bool {
            lhs.processID == rhs.processID && CFEqual(lhs.element, rhs.element)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(processID)
            hasher.combine(CFHash(element))
        }
    }

    private let lock = NSLock()
    private var established: [Key: Int] = [:]
    private var enumerated : [Key: Int] = [:]

    package init() {}

    /// How many elements the cache carries from one pass into the next. The
    /// unit tier reads it to hold the cache to the windows one pass enumerated
    /// instead of every window a long session ever opened.
    package var count: Int {
        lock.lock()
        defer { lock.unlock() }

        return established.count
    }

    /// Answers this element's Window ID from the cache, or runs `read` once and
    /// remembers the number it produced.
    ///
    /// A miss returns the read's own result, failure and associated values
    /// included, so a pass that misses everything behaves as an uncached pass
    /// did. A failure is never stored: a read that could not complete describes
    /// the moment, not the window.
    package func windowNumber<Failure: Error>(
        of element       : AXUIElement,
        ownedBy processID: Int32,
        otherwise read   : () -> Result<Int, Failure>
    ) -> Result<Int, Failure> {

        let key = Key(processID: processID, element: element)
        lock.lock()
        // What this pass already resolved answers too, so the application's
        // main and focused window cost nothing once its list has been walked.
        let known = enumerated[key] ?? established[key]
        lock.unlock()

        // The read is a bounded accessibility round trip, so it runs outside
        // the lock: no pass waits on another seat's window list.
        let result = known.map { Result<Int, Failure>.success($0) } ?? read()
        guard case .success(let number) = result else { return result }

        lock.lock()
        enumerated[key] = number
        lock.unlock()
        return result
    }

    /// Ends one pass: what that pass resolved becomes the whole cache.
    package func endPass() {
        lock.lock()
        defer { lock.unlock() }

        established = enumerated
        enumerated  = [:]
    }

    /// Drops every entry, so the next pass reads every Window ID afresh and
    /// produces what an uncached pass produces.
    package func removeAll() {
        lock.lock()
        defer { lock.unlock() }

        established = [:]
        enumerated  = [:]
    }
}
