import LocatorCore

/// Routes scrolling to the right driver per container: AX containers (axPath != nil) → `LiveScrollDriver`
/// (set AXScrollBar value); opaque CV-only containers → `OpaqueScrollDriver` (synthetic wheel + NCC
/// movement). Presents a single `ScrollDriving` to `ContinuousScrollRelocator`.
public struct CompositeScrollDriver: ScrollDriving {
    let live: LiveScrollDriver
    let opaque: OpaqueScrollDriver

    public init(live: LiveScrollDriver, opaque: OpaqueScrollDriver) {
        self.live = live
        self.opaque = opaque
    }

    public func beginPlan(for descriptor: Descriptor) async -> ScrollPlan? {
        if let p = await live.beginPlan(for: descriptor) { ScrollLog.d("driver = AX/live (settable AXScrollBar)"); return p }   // AX containers first
        if let p = await opaque.beginPlan(for: descriptor) { ScrollLog.d("driver = opaque/synthetic-wheel (no AX scroll area)"); return p }  // else opaque (CV) fallback
        ScrollLog.d("driver = none (no scrollable container resolved live)")
        return nil
    }

    public func apply(_ action: ScrollAction, for descriptor: Descriptor) async -> Double {
        let isAX = descriptor.geometry.scrollContainersAtCapture?
            .first { $0.id == action.containerID }?.axPath != nil
        ScrollLog.d("apply via \(isAX ? "AX/live" : "opaque/wheel") driver, container '\(action.containerID)'")
        return isAX ? await live.apply(action, for: descriptor) : await opaque.apply(action, for: descriptor)
    }

    public func reverseOnStall(for descriptor: Descriptor) async -> Bool {
        await opaque.reverseOnStall(for: descriptor)   // only the opaque blind search reverses; AX self-searches
    }
}
