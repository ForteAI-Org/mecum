//
//  AccessibilityWindowNumberCacheTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 17/09/2026.
//

import ApplicationServices
import CoreFoundation
@testable import SeatSession
import Testing

@Suite("The accessibility Window ID cache")
struct AccessibilityWindowNumberCacheTests {

    private struct ReadFailure: Error, Equatable {
        let attempts: Int
    }

    @Test("two accessibility elements for the same target are one key")
    func separatelyCreatedElementsCompareEqual() {
        // The whole cache rests on this: a pass creates its elements afresh, so
        // a hit needs a second element for the same target to match the first.
        let first  = AXUIElementCreateApplication(4_242)
        let second = AXUIElementCreateApplication(4_242)
        let other  = AXUIElementCreateApplication(4_343)

        #expect(first !== second)
        #expect(CFEqual(first, second))
        #expect(CFHash(first) == CFHash(second))
        #expect(!CFEqual(first, other))
    }

    @Test("a miss runs the read and reproduces its result, hit or failure")
    func missReproducesTheUncachedRead() {
        let cache   = AccessibilityWindowNumberCache()
        let element = AXUIElementCreateApplication(4_242)
        var reads   = 0

        let resolved: Result<Int, ReadFailure> =
            cache.windowNumber(of: element, ownedBy: 77) {
                reads += 1
                return .success(41)
            }
        #expect((try? resolved.get()) == 41)
        #expect(reads == 1)

        // Within the pass that resolved it, and in the pass after it.
        for _ in 0..<2 {
            let hit: Result<Int, ReadFailure> = cache.windowNumber(of: element, ownedBy: 77) {
                reads += 1
                return .success(99)
            }
            #expect((try? hit.get()) == 41)
            #expect(reads == 1)
            cache.endPass()
        }

        // A failure is the read's own, associated values included, and it is
        // not remembered: the next pass asks again.
        let unreadable = AXUIElementCreateApplication(4_343)
        let failed: Result<Int, ReadFailure> = cache.windowNumber(of: unreadable, ownedBy: 77) {
            reads += 1
            return .failure(ReadFailure(attempts: 2))
        }
        guard case .failure(let failure) = failed else {
            Issue.record("an unreadable window identity was answered from the cache")
            return
        }
        #expect(failure == ReadFailure(attempts: 2))
        #expect(reads == 2)

        let retried: Result<Int, ReadFailure> = cache.windowNumber(of: unreadable, ownedBy: 77) {
            reads += 1
            return .success(42)
        }
        #expect((try? retried.get()) == 42)
        #expect(reads == 3)
    }

    @Test("the same element under another process identity is a different entry")
    func processIdentityParticipatesInTheKey() {
        let cache   = AccessibilityWindowNumberCache()
        let element = AXUIElementCreateApplication(4_242)
        var reads   = 0

        for processID in [Int32(77), 78] {
            let resolved: Result<Int, ReadFailure> =
                cache.windowNumber(of: element, ownedBy: processID) {
                    reads += 1
                    return .success(Int(processID))
                }
            #expect((try? resolved.get()) == Int(processID))
        }

        #expect(reads == 2)
    }

    @Test("the cache holds what the last pass enumerated and nothing older")
    func theCacheDoesNotGrowBeyondOnePass() {
        let cache = AccessibilityWindowNumberCache()

        for window in 1...200 {
            let resolved: Result<Int, ReadFailure> = cache.windowNumber(
                of: AXUIElementCreateApplication(Int32(window)),
                ownedBy: 77
            ) { .success(window) }
            #expect((try? resolved.get()) == window)
        }
        cache.endPass()
        #expect(cache.count == 200)

        // The seat stops driving that process and drives one window of another.
        let resolved: Result<Int, ReadFailure> = cache.windowNumber(
            of: AXUIElementCreateApplication(1),
            ownedBy: 78
        ) { .success(1) }
        #expect((try? resolved.get()) == 1)
        cache.endPass()
        #expect(cache.count == 1)
    }

    @Test("emptying the cache restores the uncached pass")
    func removeAllRestoresTheUncachedRead() {
        let cache   = AccessibilityWindowNumberCache()
        let element = AXUIElementCreateApplication(4_242)
        var reads   = 0

        for _ in 0..<3 {
            let resolved: Result<Int, ReadFailure> = cache.windowNumber(of: element, ownedBy: 77) {
                reads += 1
                return .success(41)
            }
            #expect((try? resolved.get()) == 41)
            cache.endPass()
            cache.removeAll()
        }

        #expect(reads == 3)
        #expect(cache.count == 0)
    }
}
