//
//  WindowElementCacheTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 17/09/2026.
//

import ApplicationServices
import CoreFoundation
import SeatCore
import Testing
@testable import WindowPlacement

/// What the cache is allowed to save and what it is not. Resolving a real
/// element needs a real window and the Accessibility grant, so the suite drives
/// the two round trips as closures: the check that proves a hit, and the full
/// resolution behind it. What it holds the cache to is that the search is what
/// disappears and the check never does.
@Suite("The relocator's window element cache proves every hit")
struct WindowElementCacheTests {

    private struct ResolutionFailure: Error, Equatable {
        let windowNumber: Int
    }

    private static func identity(_ windowNumber: Int, of processID: Int32 = 4_242) -> WindowIdentity {
        WindowIdentity(
            process          : ProcessIdentity(
                processID       : processID,
                serialNumberHigh: 0,
                serialNumberLow : UInt32(processID)
            ),
            windowNumber     : windowNumber,
            ownerConnectionID: 7
        )
    }

    @Test("a hit that answers the asked for Window ID is used, and the list is not searched again")
    func provenHitReplacesTheSearch() {
        let cache    = WindowElementCache()
        let window   = Self.identity(41)
        let resolved = AXUIElementCreateApplication(4_242)
        var searches = 0
        var checks   = 0

        for _ in 0..<3 {
            let answer = cache.element(
                for        : window,
                confirmedBy: { _ in checks += 1; return 41 },
                otherwise  : { searches += 1; return resolved }
            )
            #expect(CFEqual(answer, resolved))
        }
        // One search for the miss, and one check per hit after it: the saved
        // round trips are the window list and its per element identity calls.
        #expect(searches == 1)
        #expect(checks   == 2)
    }

    @Test("a hit that answers a different Window ID, or none, is dropped rather than used")
    func staleHitFallsThroughToTheFullResolution() {
        let cache  = WindowElementCache()
        let window = Self.identity(41)
        let first  = AXUIElementCreateApplication(4_242)
        let second = AXUIElementCreateApplication(4_343)

        var answered: Int?
        var resolved = first
        var searches = 0

        func resolve() -> AXUIElement {
            searches += 1
            return resolved
        }

        answered = 41
        #expect(CFEqual(cache.element(for: window, confirmedBy: { _ in answered }, otherwise: resolve), first))
        #expect(searches == 1)

        // A Window ID the server handed out to another window: the entry names
        // a window that is gone, so it is dropped and the search runs again.
        answered = 99
        resolved = second
        #expect(CFEqual(cache.element(for: window, confirmedBy: { _ in answered }, otherwise: resolve), second))
        #expect(searches == 2)

        // No answer at all, which is what a destroyed element, a missing
        // Accessibility grant and an unresolved symbol all produce.
        answered = nil
        #expect(CFEqual(cache.element(for: window, confirmedBy: { _ in answered }, otherwise: resolve), second))
        #expect(searches == 3)

        answered = 41
        #expect(CFEqual(cache.element(for: window, confirmedBy: { _ in answered }, otherwise: resolve), second))
        #expect(searches == 3)
    }

    @Test("a resolution that refuses is the caller's own refusal and is never remembered")
    func aRefusedResolutionIsNotRemembered() {
        let cache  = WindowElementCache()
        let window = Self.identity(41)

        #expect(throws: ResolutionFailure(windowNumber: 41)) {
            try cache.element(
                for        : window,
                confirmedBy: { _ in 41 },
                otherwise  : { throw ResolutionFailure(windowNumber: 41) }
            )
        }
        #expect(cache.count == 0)

        var checks = 0
        let resolved = cache.element(
            for        : window,
            confirmedBy: { _ in checks += 1; return 41 },
            otherwise  : { AXUIElementCreateApplication(4_242) }
        )
        #expect(CFEqual(resolved, AXUIElementCreateApplication(4_242)))
        #expect(checks == 0)
    }

    @Test("the cache stays inside its bound instead of growing with the session")
    func theCacheIsBounded() {
        let cache = WindowElementCache()

        for number in 1...200 {
            _ = cache.element(
                for        : Self.identity(number),
                confirmedBy: { _ in nil },
                otherwise  : { AXUIElementCreateApplication(4_242) }
            )
        }
        #expect(cache.count <= 8)
        #expect(cache.count >= 1)
    }

    @Test("windows of two processes with the same Window ID are two entries")
    func theKeyIsTheWholeAttestedIdentity() {
        let cache    = WindowElementCache()
        let mine     = Self.identity(41, of: 4_242)
        let another  = Self.identity(41, of: 4_343)
        var searches = 0

        for window in [mine, another, mine, another] {
            _ = cache.element(
                for        : window,
                confirmedBy: { _ in 41 },
                otherwise  : {
                    searches += 1
                    return AXUIElementCreateApplication(window.processID)
                }
            )
        }
        #expect(searches == 2)
        #expect(cache.count == 2)
    }
}
