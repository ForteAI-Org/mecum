import Foundation

/// PERMANENT, env-gated (LOCATOR_TIMING=1) per-stage wall-clock telemetry to stderr. Zero work when the
/// env var is absent. This exists because ad-hoc timing had to be rebuilt for three separate perf hunts
/// (the Finder AXaugment 18.8s bug, the Premiere `scene` hang, and a parallel session re-adding the same
/// scaffolding); the pattern earned permanence. The START line prints at init — a run that hangs before
/// the first stamp indicts the first stage, and a run with NO start line indicts the caller.
public final class StageTimer {
    private let on = ProcessInfo.processInfo.environment["LOCATOR_TIMING"] != nil
    private let label: String
    private let t0 = Date()
    private var last: Date

    public init(_ label: String) {
        self.label = label
        self.last = t0
        if on { FileHandle.standardError.write(Data("⏱ \(label) — start (pid \(getpid()))\n".utf8)) }
    }

    /// Print the time since the previous stamp (and cumulative since init).
    public func stamp(_ stage: String) {
        guard on else { return }
        let n = Date()
        FileHandle.standardError.write(Data(String(format: "⏱ %@ — %@: %.3fs (cum %.3fs)\n",
                                                   label, stage, n.timeIntervalSince(last), n.timeIntervalSince(t0)).utf8))
        last = n
    }
}
