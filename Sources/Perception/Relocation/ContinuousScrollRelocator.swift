import Foundation
import LocatorCore

/// Drives scrolling for the continuous relocator, abstracted so the loop is testable with a mock (no
/// AX, no live window). The live conformance resolves the scroll container via its recorded AX path,
/// reads its scroll fraction, sets it, and measures whether the content actually moved.
public protocol ScrollDriving: Sendable {
    /// Build a bounded scroll plan for an off-screen descriptor (resolve its container + read the
    /// current fraction). Returns nil when there's no scrollable container to act on (→ honest miss).
    func beginPlan(for descriptor: Descriptor) async -> ScrollPlan?
    /// Apply one absolute scroll, then return the MEASURED movement fraction (0 ⇒ pane didn't move —
    /// blocked/virtualized/already-there). The driver settles animation before measuring. `descriptor`
    /// carries the container's recorded AX path so the driver can re-resolve it.
    func apply(_ action: ScrollAction, for descriptor: Descriptor) async -> Double
    /// Asked once the bounded loop would otherwise give up (stalled at a boundary). A driver that can
    /// still search ANOTHER direction reverses internally and returns `true`, so the loop resumes the
    /// other way instead of quitting. Used by the opaque BLIND search (no text → direction is a guess, so
    /// a target that's actually the other way must not be abandoned at the first boundary). Default: no
    /// reversal — text-target drivers self-reverse within a single plan, AX drivers search a full range.
    func reverseOnStall(for descriptor: Descriptor) async -> Bool
}

public extension ScrollDriving {
    func reverseOnStall(for descriptor: Descriptor) async -> Bool { false }
}

/// The continuous, scroll-aware relocator: a thin bounded loop that WRAPS the existing cascade as its
/// `locate` primitive (it does not modify it). On a `.offscreen` outcome it scrolls the right container
/// toward where the target was, RE-LOCATES on a fresh capture, and repeats under hard guards. Because
/// every re-locate runs the unchanged, fully-gated cascade, the loop can only ever turn
/// `.offscreen → .hit` or `.offscreen → honest miss` — never `.offscreen → wrong click`.
///
/// Conforms to `StepRelocating`, so it drops into `FlowRunner` with zero runner change. Gated by
/// `autoScroll` (default off elsewhere) so existing behaviour is byte-identical unless opted in.
public struct ContinuousScrollRelocator: StepRelocating {
    let inner: any StepRelocating       // the cascade (a fresh capture per call → fresh frameCache)
    let driver: any ScrollDriving
    let tuning: RelocationTuning
    let autoScroll: Bool

    public init(inner: any StepRelocating, driver: any ScrollDriving,
                tuning: RelocationTuning = .defaults, autoScroll: Bool = true) {
        self.inner = inner
        self.driver = driver
        self.tuning = tuning
        self.autoScroll = autoScroll
    }

    public func relocate(_ descriptor: Descriptor) async -> RelocationResult {
        var result = await inner.relocate(descriptor)
        ScrollLog.d("initial relocate '\(descriptor.text.selfText ?? "")' → \(result.method.rawValue)")
        if found(result) { return result }
        // Earn a scroll attempt when EITHER the cascade said .offscreen (AX: exists-but-hidden) OR it
        // missed but the element has a recorded scroll container (the CV case — e.g. a WhatsApp chat with
        // no AX path: we can't know it's hidden vs gone, so scroll-SEARCH its container; a bounded miss
        // then becomes an honest .notFound). Both paths re-locate through the unchanged gated cascade.
        let hasContainer = descriptor.geometry.scrollContainersAtCapture?.isEmpty == false
        guard autoScroll else { ScrollLog.d("autoScroll off — not scrolling"); return result }
        guard result.method == .offscreen || (result.method == .notFound && hasContainer) else {
            ScrollLog.d("not scrolling: method=\(result.method.rawValue), hasContainer=\(hasContainer)")
            return result
        }
        guard var plan = await driver.beginPlan(for: descriptor) else {
            ScrollLog.d("no scroll plan (container unresolved / pane changed) → honest \(result.method.rawValue)")
            return result
        }
        ScrollLog.d("scrolling \(descriptor.geometry.scrollContainersAtCapture?.count ?? 0) container(s) to find '\(descriptor.text.selfText ?? "")'")

        var iterations = 0
        var consecutiveStalls = 0
        var everMoved = false
        while iterations < tuning.maxScrollIterations, plan.canScroll,
              let action = ScrollPlanner.next(&plan) {
            iterations += 1
            let moved = await driver.apply(action, for: descriptor)
            // ANY real movement is PROGRESS, never a stall — small adaptive steps register a small
            // region-change (e.g. ~0.005 for a few rows), well below a big burst's, so the threshold must
            // be low enough to count them. A move resets the stall budget and re-locates on the new frame.
            if moved > tuning.contentMovedEpsilon {
                everMoved = true
                consecutiveStalls = 0
                result = await inner.relocate(descriptor)   // re-locate on a NEW capture
                if found(result) { ScrollLog.d("located after \(iterations) scroll(s) → \(result.method.rawValue)"); break }
                continue
            }
            // No real movement (pixel-near-identical) → don't waste an OCR. Stay impatient (2 strikes)
            // until the pane PROVES it can move; then a proven-live pane earns the larger end-of-list
            // budget — so a dead/blocked pane still bails fast, but one dropped burst can't abandon a far
            // target mid-list while it's actually making progress.
            consecutiveStalls += 1
            let stallLimit = everMoved ? tuning.endOfListStallLimit : 2
            if consecutiveStalls >= stallLimit {
                // Before giving up: a blind opaque search (no text to infer direction) can REVERSE once and
                // hunt the other way — a target that's actually DOWN must not be abandoned just because the
                // direction guess walked us UP into a boundary (the Slack no-text sidebar case). Text targets
                // and AX containers return false here (they self-reverse / search a full range already).
                if await driver.reverseOnStall(for: descriptor) {
                    ScrollLog.d("reversing search direction after \(consecutiveStalls) stall(s)")
                    consecutiveStalls = 0
                    everMoved = true   // give the reverse leg the full end-of-list stall budget
                    continue
                }
                ScrollLog.d("stalled (\(consecutiveStalls) no-move bursts, everMoved=\(everMoved)) → \(result.method.rawValue)")
                break
            }
        }
        ScrollLog.d("scroll loop ended after \(iterations) iter(s), everMoved=\(everMoved) → \(result.method.rawValue)")
        return result   // exhausted → still not found; FlowRunner's !actuated gate then halts the flow
    }

    /// A clicking-usable hit: a real cascade stage resolved it. `.offscreen` reports isHit==true (the
    /// element exists) but is NOT clickable, so it does not count as found.
    private func found(_ r: RelocationResult) -> Bool { r.isHit && r.method != .offscreen }
}
