//
//  WindowServerReadingCacheTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

import CoreGraphics
@testable import SeatCapture
import SeatCore
import Testing

@Suite("The window server answers a running stream reuses between frames")
struct WindowServerReadingCacheTests {

    private let bound = WindowServerReadingCache.refreshIntervalNanoseconds
    private let rect  = CGRect(x: 10, y: 20, width: 300, height: 200)
    private let shape = WindowServerReadingCache.FrameShape(
        pixelSize   : CGSize(width: 600, height: 400),
        scaleFactor : 2,
        contentScale: 1
    )

    /// Counts what the cache actually asked the window server.
    private final class Reads {
        var count = 0
    }

    @Test("the rectangle is read once and then served from the cache inside the bound")
    func geometryIsReadOnce() {
        let cache = WindowServerReadingCache()
        let reads = Reads()
        let read: () -> CGRect? = { reads.count += 1; return self.rect }

        for frame in 0..<30 {
            #expect(cache.screenRect(at: UInt64(frame) * 33_000_000, for: shape, read: read) == rect)
        }
        #expect(reads.count == 1)
    }

    @Test("each trigger reads the rectangle again: the bound, another shape, an invalidation")
    func geometryIsReadAgainOnEveryTrigger() {
        let cache = WindowServerReadingCache()
        let reads = Reads()
        let read: () -> CGRect? = { reads.count += 1; return self.rect }

        _ = cache.screenRect(at: 0, for: shape, read: read)
        _ = cache.screenRect(at: bound - 1, for: shape, read: read)
        #expect(reads.count == 1)

        _ = cache.screenRect(at: bound, for: shape, read: read)
        #expect(reads.count == 2)

        var resized = shape
        resized.pixelSize = CGSize(width: 640, height: 400)
        _ = cache.screenRect(at: bound + 1, for: resized, read: read)
        #expect(reads.count == 3)

        var rescaled = resized
        rescaled.scaleFactor = 1
        _ = cache.screenRect(at: bound + 2, for: rescaled, read: read)
        #expect(reads.count == 4)

        cache.invalidate()
        _ = cache.screenRect(at: bound + 3, for: rescaled, read: read)
        #expect(reads.count == 5)
    }

    @Test("an empty answer is not kept, so the next frame asks again")
    func absentGeometryIsNotCached() {
        let cache = WindowServerReadingCache()
        let reads = Reads()
        let read: () -> CGRect? = { reads.count += 1; return nil }

        #expect(cache.screenRect(at: 0, for: shape, read: read) == nil)
        #expect(cache.screenRect(at: 1, for: shape, read: read) == nil)
        #expect(reads.count == 2)
    }

    @Test("identity is checked on the first frame, again only after the bound or an invalidation")
    func identityIsRecheckedOnBoundExpiry() {
        let cache = WindowServerReadingCache()
        let checks = Reads()
        let check: () -> CaptureFailure? = { checks.count += 1; return nil }

        #expect(cache.identityFailure(at: 0, check: check) == nil)
        #expect(cache.identityFailure(at: bound - 1, check: check) == nil)
        #expect(checks.count == 1)

        #expect(cache.identityFailure(at: bound, check: check) == nil)
        #expect(checks.count == 2)

        cache.invalidate()
        #expect(cache.identityFailure(at: bound + 1, check: check) == nil)
        #expect(checks.count == 3)
    }

    @Test("a failed identity check is reported and never cached as a success")
    func identityFailureIsNotCached() {
        let cache = WindowServerReadingCache()
        let checks = Reads()
        let changed = CaptureFailure.windowIdentityChanged(expected: FakeIdentity.window, observed: nil)
        let failing: () -> CaptureFailure? = { checks.count += 1; return changed }

        #expect(cache.identityFailure(at: 0, check: failing) == changed)
        #expect(cache.identityFailure(at: 1, check: failing) == changed)
        #expect(checks.count == 2)
    }
}

private enum FakeIdentity {
    static let window = WindowIdentity(
        process          : ProcessIdentity(processID: 42, serialNumberHigh: 1, serialNumberLow: 2),
        windowNumber     : 7,
        ownerConnectionID: 3
    )
}
