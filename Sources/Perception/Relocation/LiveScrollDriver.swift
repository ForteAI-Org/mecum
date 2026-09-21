import Foundation
import AppKit
import AXSupport
import LocatorCore

/// Live `ScrollDriving` for native AX scroll areas (Phase 1): re-resolve the recorded scroll container
/// by its AX path, read its scroll-bar fraction, drive it to an absolute target, and measure whether the
/// content actually moved (read-after-write). AX-only — a CV-only container (no AX path) yields no plan,
/// so opaque apps fall through to today's honest miss (CV scroll is a later phase). All AX work hops to
/// the main actor; only Sendable data (fractions) crosses back.
public struct LiveScrollDriver: ScrollDriving {
    let ax: AXEngine
    let tuning: RelocationTuning
    let settleSeconds: Double

    public init(ax: AXEngine, tuning: RelocationTuning = .defaults, settleSeconds: Double = 0.2) {
        self.ax = ax
        self.tuning = tuning
        self.settleSeconds = settleSeconds
    }

    public func beginPlan(for d: Descriptor) async -> ScrollPlan? {
        guard let snap = d.geometry.scrollContainersAtCapture?.first(where: { $0.axPath != nil }),
              let path = snap.axPath, let axis = snap.axes.first else { return nil }
        return await MainActor.run { () -> ScrollPlan? in
            guard let pid = Self.pid(d.app.bundleID),
                  let container = ax.replayPath(path, inApp: pid),
                  let current = ax.scrollFraction(of: container, axis: axis) else { return nil }
            let captured = axis == .vertical ? snap.scrollFractionAtCapture.y : snap.scrollFractionAtCapture.x
            return ScrollPlanner.makePlan(containerID: snap.id, axis: axis,
                                          capturedFraction: Double(captured), currentFraction: current,
                                          stepFraction: tuning.scrollStepFraction)
        }
    }

    public func apply(_ action: ScrollAction, for d: Descriptor) async -> Double {
        guard case .absoluteFraction = action.strategy else { return 0 }   // AX path only; opaque steps are someone else's
        guard let snap = d.geometry.scrollContainersAtCapture?.first(where: { $0.id == action.containerID }),
              let path = snap.axPath else { return 0 }
        // Read-before, command the absolute fraction.
        let before = await MainActor.run { () -> Double? in
            guard let pid = Self.pid(d.app.bundleID), let c = ax.replayPath(path, inApp: pid) else { return nil }
            let b = ax.scrollFraction(of: c, axis: action.axis)
            ax.setScrollFraction(of: c, axis: action.axis, action.targetFraction)
            return b
        }
        guard let before else { return 0 }
        try? await Task.sleep(for: .seconds(settleSeconds))   // let momentum/animation settle before measuring
        // Read-after → measured movement (0 ⇒ the pane ignored us: blocked/virtualized/already-there).
        let after = await MainActor.run { () -> Double? in
            guard let pid = Self.pid(d.app.bundleID), let c = ax.replayPath(path, inApp: pid) else { return nil }
            return ax.scrollFraction(of: c, axis: action.axis)
        }
        guard let after else { return 0 }
        return abs(after - before)
    }

    @MainActor private static func pid(_ bundleID: String) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
    }
}
