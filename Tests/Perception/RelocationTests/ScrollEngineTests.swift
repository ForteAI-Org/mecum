import XCTest
import CoreGraphics
@testable import Relocation
import CVBackend
import LocatorCore

// MARK: ScrollPlanner (pure)

final class ScrollPlannerTests: XCTestCase {
    func testRestoresCapturePositionFirst() {
        let plan = ScrollPlanner.makePlan(containerID: "c", axis: .vertical,
                                          capturedFraction: 0.5, currentFraction: 0.0, stepFraction: 0.2)
        var p = plan
        XCTAssertEqual(ScrollPlanner.next(&p)?.targetFraction, 0.5)   // try where it WAS visible first
        XCTAssertEqual(ScrollPlanner.next(&p)?.axis, .vertical)
        XCTAssertEqual(ScrollPlanner.next(&p)?.containerID, "c")
    }

    func testPlanIsFiniteClampedAndDeduped() {
        let plan = ScrollPlanner.makePlan(containerID: "c", axis: .vertical,
                                          capturedFraction: 0.9, currentFraction: 0.1, stepFraction: 0.2)
        var p = plan
        var seen: [Double] = []
        while let a = ScrollPlanner.next(&p) { seen.append(a.targetFraction) }
        XCTAssertFalse(seen.isEmpty)
        XCTAssertLessThan(seen.count, 20)                                  // finite — can't loop forever
        XCTAssertTrue(seen.allSatisfy { $0 >= 0 && $0 <= 1 })              // clamped to [0,1]
        for i in seen.indices { for j in seen.indices where j > i { XCTAssertGreaterThan(abs(seen[i] - seen[j]), 0.019) } } // deduped
        XCTAssertTrue(seen.contains { abs($0 - 1.0) < 0.001 })             // extremes covered
        XCTAssertTrue(seen.contains { abs($0 - 0.0) < 0.001 })
    }
}

// MARK: ContinuousScrollRelocator (the loop)

private final class MockInner: StepRelocating, @unchecked Sendable {
    var results: [RelocationResult]
    private(set) var calls = 0
    init(_ results: [RelocationResult]) { self.results = results }
    func relocate(_ d: Descriptor) async -> RelocationResult {
        defer { calls += 1 }
        return results[min(calls, results.count - 1)]   // last result repeats
    }
}

private final class MockDriver: ScrollDriving, @unchecked Sendable {
    var plan: ScrollPlan?
    var movements: [Double]
    let maxReversals: Int
    private(set) var applied: [ScrollAction] = []
    private(set) var reversals = 0
    private var n = 0
    init(plan: ScrollPlan?, movements: [Double], maxReversals: Int = 0) {
        self.plan = plan; self.movements = movements; self.maxReversals = maxReversals
    }
    func beginPlan(for d: Descriptor) async -> ScrollPlan? { plan }
    func apply(_ a: ScrollAction, for d: Descriptor) async -> Double { applied.append(a); defer { n += 1 }; return movements[min(n, movements.count - 1)] }
    func reverseOnStall(for d: Descriptor) async -> Bool { if reversals < maxReversals { reversals += 1; return true }; return false }
}

private func hit() -> RelocationResult { .init(elementRectScreenPt: .init(x: 0, y: 0, width: 1, height: 1), method: .geometryNCC, confidence: 1) }
private func offscreen() -> RelocationResult { .init(method: .offscreen, confidence: 0) }
private func notFound() -> RelocationResult { .init(method: .notFound, confidence: 0) }
private func samplePlan() -> ScrollPlan {
    ScrollPlanner.makePlan(containerID: "c", axis: .vertical, capturedFraction: 0.5, currentFraction: 0.0, stepFraction: 0.2)
}

final class ContinuousScrollRelocatorTests: XCTestCase {
    private func descriptor() -> Descriptor { makeDescriptor() }

    func testHitReturnsImmediatelyWithoutScrolling() async {
        let inner = MockInner([hit()])
        let driver = MockDriver(plan: samplePlan(), movements: [0.2])
        let r = await ContinuousScrollRelocator(inner: inner, driver: driver).relocate(descriptor())
        XCTAssertTrue(r.isHit)
        XCTAssertEqual(inner.calls, 1)
        XCTAssertTrue(driver.applied.isEmpty)   // never scrolled — it was already on screen
    }

    func testHonestNotFoundReturnsImmediately() async {
        let inner = MockInner([notFound()])
        let driver = MockDriver(plan: samplePlan(), movements: [0.2])
        let r = await ContinuousScrollRelocator(inner: inner, driver: driver).relocate(descriptor())
        XCTAssertEqual(r.method, .notFound)
        XCTAssertTrue(driver.applied.isEmpty)
    }

    func testNotFoundWithScrollContainerScrollSearchesAndFinds() async {
        // The CV case (e.g. a WhatsApp chat, no AX path): a miss WITH a recorded scroll container should
        // scroll-search the container; a real hit after scrolling is clicked.
        var d = makeDescriptor()
        d.geometry.scrollContainersAtCapture = [ScrollContainerSnapshot(
            id: "c", axes: [.vertical], boundsNormalized: CGRect(x: 0, y: 0, width: 0.3, height: 1),
            scrollFractionAtCapture: CGPoint(x: 0, y: 0.5))]
        let inner = MockInner([notFound(), hit()])
        let driver = MockDriver(plan: samplePlan(), movements: [0.2])
        let r = await ContinuousScrollRelocator(inner: inner, driver: driver).relocate(d)
        XCTAssertTrue(r.isHit)
        XCTAssertEqual(r.method, .geometryNCC)
        XCTAssertEqual(driver.applied.count, 1)
    }

    func testOffscreenScrollsThenFinds() async {
        let inner = MockInner([offscreen(), hit()])   // miss-offscreen, then found after one scroll
        let driver = MockDriver(plan: samplePlan(), movements: [0.2])
        let r = await ContinuousScrollRelocator(inner: inner, driver: driver).relocate(descriptor())
        XCTAssertTrue(r.isHit)
        XCTAssertEqual(r.method, .geometryNCC)
        XCTAssertEqual(driver.applied.count, 1)
        XCTAssertEqual(driver.applied.first?.targetFraction, 0.5)   // restored capture position first
        XCTAssertEqual(inner.calls, 2)
    }

    func testNoScrollContainerReturnsOffscreen() async {
        let inner = MockInner([offscreen()])
        let driver = MockDriver(plan: nil, movements: [0.2])   // no scrollable container
        let r = await ContinuousScrollRelocator(inner: inner, driver: driver).relocate(descriptor())
        XCTAssertEqual(r.method, .offscreen)
        XCTAssertTrue(driver.applied.isEmpty)
    }

    func testStallBreaksHonestly() async {
        let inner = MockInner([offscreen()])               // never found
        let driver = MockDriver(plan: samplePlan(), movements: [0.0])   // pane never moves
        let r = await ContinuousScrollRelocator(inner: inner, driver: driver).relocate(descriptor())
        XCTAssertEqual(r.method, .offscreen)               // gives up honestly
        XCTAssertEqual(driver.applied.count, 2)            // breaks after 2 consecutive stalls
    }

    func testSmallRealMoveRelocatesAndCanFind() async {
        // A small adaptive step registers a small region-change (~0.005) — above the (low) movement
        // threshold, so it counts as progress: re-locate, and a real hit after it is clicked.
        let inner = MockInner([offscreen(), hit()])
        let driver = MockDriver(plan: samplePlan(), movements: [0.005])   // > contentMovedEpsilon (0.003)
        let r = await ContinuousScrollRelocator(inner: inner, driver: driver).relocate(descriptor())
        XCTAssertTrue(r.isHit)
        XCTAssertEqual(driver.applied.count, 1)
        XCTAssertEqual(inner.calls, 2)             // initial miss + one relocate after the move
    }

    func testDeliveryHiccupDoesNotEndHuntAfterMotion() async {
        // Once the pane has PROVEN it can move, a couple of dropped/dead bursts must NOT be mistaken for
        // end-of-list: the budget rises to endOfListStallLimit (3), so a far target isn't abandoned mid-list.
        let inner = MockInner([offscreen()])                       // never found
        let driver = MockDriver(plan: samplePlan(), movements: [0.2, 0.0, 0.0, 0.0])  // one real move, then dead frames
        let r = await ContinuousScrollRelocator(inner: inner, driver: driver).relocate(descriptor())
        XCTAssertEqual(r.method, .offscreen)
        XCTAssertEqual(driver.applied.count, 4)    // 1 real move + 3 dead frames (was 3 under the old 2-strike rule)
    }

    func testRespectsIterationCap() async {
        let inner = MockInner([offscreen()])               // never found
        let driver = MockDriver(plan: samplePlan(), movements: [0.2])   // always moves, never finds
        let tuning = RelocationTuning(maxScrollIterations: 3)
        let r = await ContinuousScrollRelocator(inner: inner, driver: driver, tuning: tuning).relocate(descriptor())
        XCTAssertEqual(r.method, .offscreen)
        XCTAssertEqual(driver.applied.count, 3)            // hard cap, no infinite scroll
        XCTAssertEqual(inner.calls, 1 + 3)                 // initial + one re-locate per iteration
    }

    func testAutoScrollOffNeverScrolls() async {
        let inner = MockInner([offscreen()])
        let driver = MockDriver(plan: samplePlan(), movements: [0.2])
        let r = await ContinuousScrollRelocator(inner: inner, driver: driver, autoScroll: false).relocate(descriptor())
        XCTAssertEqual(r.method, .offscreen)
        XCTAssertTrue(driver.applied.isEmpty)
    }

    func testReverseOnStallResumesOtherDirectionAndFinds() async {
        // The Slack no-text case: the blind search walks one way (a move, then a boundary it stalls into),
        // would normally give up — but reverseOnStall lets it flip ONCE and keep hunting, finding the
        // target the other way instead of a false honest-miss.
        let inner = MockInner([offscreen(), offscreen(), hit()])               // found only after the reverse
        let driver = MockDriver(plan: samplePlan(), movements: [0.2, 0.0, 0.0, 0.0, 0.2], maxReversals: 1)
        let r = await ContinuousScrollRelocator(inner: inner, driver: driver).relocate(descriptor())
        XCTAssertTrue(r.isHit)
        XCTAssertEqual(driver.reversals, 1)                                    // it reversed exactly once
        XCTAssertEqual(driver.applied.count, 5)                                // 1 move + 3 stalls (→reverse) + 1 move→hit
    }

    func testReverseOnStallOnlyOnceThenHonestMiss() async {
        // A driver that can reverse only once: if BOTH directions stall, the loop still terminates honestly
        // (no infinite flip-flop).
        let inner = MockInner([offscreen()])                                   // never found
        let driver = MockDriver(plan: samplePlan(), movements: [0.2, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], maxReversals: 1)
        let r = await ContinuousScrollRelocator(inner: inner, driver: driver).relocate(descriptor())
        XCTAssertEqual(r.method, .offscreen)
        XCTAssertEqual(driver.reversals, 1)                                    // reversed once, then gave up
    }
}

// MARK: Opaque (no-AX) scroll helpers (pure)

final class OpaqueScrollHelperTests: XCTestCase {
    func testMakeOpaquePlanIsFiniteUniformDirectionSeeded() {
        var p = ScrollPlanner.makeOpaquePlan(containerID: "o", axis: .vertical, direction: -1, maxSteps: 8)
        var steps: [Int] = []
        while let a = ScrollPlanner.next(&p) { if case .relativeTicks(let t) = a.strategy { steps.append(t) } }
        XCTAssertEqual(steps.count, 8)                  // a finite budget of steps
        XCTAssertTrue(steps.allSatisfy { $0 < 0 })      // all seeded toward the inferred dir; the driver re-infers & reverses adaptively
    }

    func testInferDirectionFromOrderedLabels() {
        XCTAssertEqual(OpaqueScrollDriver.inferDirection(target: "Audio 3", visible: ["Audio 7", "Audio 8", "Audio 11"]), -1)
        XCTAssertEqual(OpaqueScrollDriver.inferDirection(target: "Audio 30", visible: ["Audio 7", "Audio 8"]), 1)
        // NO EVIDENCE → nil (Phase 2f): the caller runs the reversible BLIND search instead of a
        // hardcoded direction (the old "default up" marched into the top edge forever — measured live).
        XCTAssertNil(OpaqueScrollDriver.inferDirection(target: "Cancel", visible: ["OK", "Save"]))          // no trailing number
        XCTAssertNil(OpaqueScrollDriver.inferDirection(target: "Zebra Target 42",                          // numeric name, but its
                                                       visible: ["Line 001 — quick brown fox"]))           // family isn't on screen
    }

    func testInferDirectionIgnoresOutOfFamilyNumericNoise() {
        // The real Pro Tools bug: a full-window OCR drags in timecodes / sample counts / clip names whose
        // numbers dwarf the track range. Family filtering keeps only "Audio N" (and the abbreviated
        // "AudN" column), so a far-DOWN target is correctly seen as below the visible Audio 1–8.
        let noisy = ["Audio 1", "Audio 8", "Aud3", "Sfx 1",
                     "00:00:14:11", "1172431", "A001_111400", "2| 3|466"]
        XCTAssertEqual(OpaqueScrollDriver.inferDirection(target: "Audio 20", visible: noisy), 1)   // down (was wrongly up)
        XCTAssertEqual(OpaqueScrollDriver.inferDirection(target: "Audio 1", visible: ["Audio 8", "Audio 17", "1172431"]), -1) // up
        XCTAssertEqual(OpaqueScrollDriver.labelPrefix("• Aud4"), "aud")
        XCTAssertEqual(OpaqueScrollDriver.labelPrefix("Audio 20 ▾"), "audio")
        XCTAssertEqual(OpaqueScrollDriver.labelPrefix("00:00:14:11"), "")
    }

    func testInferDirectionExcludesAbbreviatedNonScrollingColumn() {
        // Pro Tools' left TRACKS column shows ALL tracks abbreviated ("Aud9", "Ad10"…) and does NOT
        // scroll; the scrolling edit area uses full "Audio N". For target "Audio 9" with only Audio 1–8
        // visible, the always-present "Aud9" must NOT count toward the family max (else 9 ≯ 9 → wrong up).
        let visible = ["Audio 1", "Audio 5", "Audio 8",          // scrolling full names (what's visible)
                       "Aud1", "Aud9", "Ad10", "Ad20", "Ad30"]    // non-scrolling abbreviated column (always all)
        XCTAssertEqual(OpaqueScrollDriver.inferDirection(target: "Audio 9", visible: visible), 1)  // down
    }

    func testBisectionHalvesTicksTowardFloor() {
        // Each genuine reversal halves the per-event tick count (round-to-nearest), pinned at the floor.
        XCTAssertEqual(OpaqueScrollDriver.halve(3, floor: 1), 2)   // 3 → 1.5 → 2
        XCTAssertEqual(OpaqueScrollDriver.halve(2, floor: 1), 1)   // 2 → 1
        XCTAssertEqual(OpaqueScrollDriver.halve(1, floor: 1), 1)   // 1 → 0.5 → 1 (pinned at floor)
        XCTAssertEqual(OpaqueScrollDriver.halve(2, floor: 2), 2)   // never below floor
    }

    func testDeliveryPointParksAtRecordedClickNotRegionCenter() {
        // Window at a NON-zero global origin (proves global-points handling); full-window region (the opaque
        // fallback), scale 2 → regionPx (0,0,2000,1600) maps to live points (100,50,1000,800), center (600,450).
        let win = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let fullRegionPx = CGRect(x: 0, y: 0, width: 2000, height: 1600)

        // A real recorded click (windowRelative 0.2,0.7) is delivered AT THE CLICK, not the region center.
        let (p, _) = OpaqueScrollDriver.deliveryPoint(windowRelative: CGPoint(x: 0.2, y: 0.7),
                                                      winFrame: win, regionPx: fullRegionPx, scale: 2)
        XCTAssertEqual(p.x, 300, accuracy: 0.001)   // 100 + 0.2*1000
        XCTAssertEqual(p.y, 610, accuracy: 0.001)   // 50 + 0.7*800
        XCTAssertNotEqual(p.x, 600, accuracy: 0.001)  // NOT the region center the old code used

        // KB-reach sentinel (0.5,0.5) → fall back to the region center, byte-for-byte the old behavior.
        let (c, _) = OpaqueScrollDriver.deliveryPoint(windowRelative: CGPoint(x: 0.5, y: 0.5),
                                                      winFrame: win, regionPx: fullRegionPx, scale: 2)
        XCTAssertEqual(c.x, 600, accuracy: 0.001)
        XCTAssertEqual(c.y, 450, accuracy: 0.001)
    }

    func testDeliveryPointClampsIntoRecordedRegionAndJigglesInward() {
        let win = CGRect(x: 100, y: 50, width: 1000, height: 800)

        // A near-edge click stays inside the window, and the jiggle goes INWARD (never off-window).
        let (p, off) = OpaqueScrollDriver.deliveryPoint(windowRelative: CGPoint(x: 0.99, y: 0.99),
                                                        winFrame: win, regionPx: CGRect(x: 0, y: 0, width: 2000, height: 1600), scale: 2)
        XCTAssertTrue(win.contains(p), "delivery point must stay inside the window")
        XCTAssertTrue(win.contains(off), "inward jiggle must stay inside the window")
        XCTAssertLessThan(off.x, p.x)   // inward (toward region center at 600) → negative offset
        XCTAssertLessThan(off.y, p.y)

        // A click OUTSIDE a recorded SUB-pane is pulled back into that pane's interior (drift/heal guard).
        // regionPx (0,0,1000,800) @scale2 → live pane (100,50,500,400); a 0.9,0.9 click (→1000,770) clamps in.
        let (q, _) = OpaqueScrollDriver.deliveryPoint(windowRelative: CGPoint(x: 0.9, y: 0.9),
                                                      winFrame: win, regionPx: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 2)
        XCTAssertEqual(q.x, 596, accuracy: 0.001)   // region.maxX(600) − margin(4)
        XCTAssertEqual(q.y, 446, accuracy: 0.001)   // region.maxY(450) − margin(4)
    }

    /// Pure model of the adaptive bisection: window of `win` tracks, ~`tracksPerTick` tracks per tick, top
    /// label `pos`. Mirrors the driver's reversal-gated tick-halving. Returns true if the target's label
    /// enters the visible window within the iteration budget.
    private func converges(target: Int, start: Int, total: Int, win: Int, tracksPerTick: Int,
                           seedTicks: Int, floorTicks: Int, halving: Bool, iters: Int) -> Bool {
        var pos = start, ticks = seedTicks, lastDir = 0
        for _ in 0..<iters {
            if target >= pos && target <= pos + win - 1 { return true }     // visible → cascade finds it
            let dir = target > pos + win - 1 ? 1 : (target < pos ? -1 : 1)  // below window → down, above → up
            if halving, lastDir != 0, dir != lastDir { ticks = max(floorTicks, Int((Double(ticks)/2.0).rounded())) }
            let newPos = max(1, min(total - win + 1, pos + dir * ticks * tracksPerTick))
            if newPos != pos { lastDir = dir }                              // only a real move updates the reference
            pos = newPos
        }
        return target >= pos && target <= pos + win - 1
    }

    func testBisectionConvergesOnGapTargetWhereFixedStepOscillates() {
        // The Audio 9 bug: window 8 tracks, 3 ticks × ~4 tracks/tick = ~12-track step. Fixed step (no
        // halving) bounces 1↔13 and never shows Audio 9; bisection halves on the crossing and lands it.
        XCTAssertFalse(converges(target: 9, start: 1, total: 30, win: 8, tracksPerTick: 4,
                                 seedTicks: 3, floorTicks: 1, halving: false, iters: 12))   // oscillates forever
        XCTAssertTrue(converges(target: 9, start: 1, total: 30, win: 8, tracksPerTick: 4,
                                seedTicks: 3, floorTicks: 1, halving: true, iters: 12))      // bisection lands it
    }

    func testBisectionStillReachesFarTargetFast() {
        // A far target never reverses on the way (always same direction), so the step never shrinks → fast.
        XCTAssertTrue(converges(target: 28, start: 1, total: 30, win: 8, tracksPerTick: 4,
                                seedTicks: 3, floorTicks: 1, halving: true, iters: 12))
    }

    func testRegionChangeDetectsRealChangeAndIgnoresIdentity() {
        let before = striped(width: 80, height: 240, shift: 0)
        let shifted = striped(width: 80, height: 240, shift: 20)
        XCTAssertGreaterThan(OpaqueScrollDriver.regionChangeFraction(before: before, after: shifted), 0.02)
        XCTAssertLessThan(OpaqueScrollDriver.regionChangeFraction(before: before, after: before), 0.001) // identical → no change
    }

    func testLastIntIsRobustToTrailingChars() {
        XCTAssertEqual(OpaqueScrollDriver.lastInt("Audio 20 ▾"), 20)   // chevron after the number (the bug)
        XCTAssertEqual(OpaqueScrollDriver.lastInt("Audio 3"), 3)
        XCTAssertEqual(OpaqueScrollDriver.lastInt("v4 Audio 7"), 7)    // the LAST run, not the first
        XCTAssertNil(OpaqueScrollDriver.lastInt("Cancel"))
    }

    func testRegionPixelsMapsAndRejectsTiny() {
        let r = OpaqueScrollDriver.regionPixels(CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6), imagePixelSize: CGSize(width: 1000, height: 800))
        XCTAssertEqual(r?.width ?? 0, 500, accuracy: 1)
        XCTAssertEqual(r?.minY ?? 0, 160, accuracy: 1)
        XCTAssertNil(OpaqueScrollDriver.regionPixels(CGRect(x: 0, y: 0, width: 0.001, height: 0.001), imagePixelSize: CGSize(width: 1000, height: 800)))
    }

    func testMovementMeasurementDetectsShiftAndZero() throws {
        let before = striped(width: 80, height: 240, shift: 0)
        let shifted = striped(width: 80, height: 240, shift: 20)
        let matcher = NCCTemplateMatcher()
        let moved = OpaqueScrollDriver.verticalDisplacementFraction(before: before, after: shifted, matcher: matcher)
        XCTAssertGreaterThan(moved, 0.04)                 // ~20/240 ≈ 0.083 (sign-agnostic)
        XCTAssertLessThan(moved, 0.2)
        let same = OpaqueScrollDriver.verticalDisplacementFraction(before: before, after: before, matcher: matcher)
        XCTAssertLessThan(same, 0.02)                     // identical → no movement
    }

    /// Distinctive (non-periodic) horizontal bands at fixed rows, shifted down by `shift` px.
    private func striped(width w: Int, height h: Int, shift: Int) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 0.08, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let bands: [(Int, Int, CGFloat)] = [(30, 16, 0.9), (78, 10, 0.4), (132, 22, 0.7), (190, 8, 1.0), (215, 6, 0.3)]
        for (y, bh, g) in bands {
            ctx.setFillColor(gray: g, alpha: 1)
            ctx.fill(CGRect(x: 6, y: y + shift, width: w - 12, height: bh))   // shift moves bands vertically
        }
        return ctx.makeImage()!
    }
}
