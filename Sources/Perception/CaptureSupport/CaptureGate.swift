import Foundation

/// Cross-PROCESS serialization of ScreenCaptureKit one-shot captures. Several locator processes run
/// at once (behavior watch, locator-mcp, CLI commands), each with its own SCK session; CONCURRENT
/// one-shots starve each other (measured 2026-07-02 on Pro Tools: nil scenes + leaked SCK
/// continuations whenever the watch reacted while another process captured). An advisory `flock`
/// serializes them across processes:
/// - the lock dies with its owning process (crash-safe — no stale-lock cleanup, ever)
/// - a waiter polls up to `timeout`, then PROCEEDS UNLOCKED — degraded equals the old behavior,
///   so the gate can only help, never make a capture impossible.
public enum CaptureGate {
    static var lockPath: String { "/tmp/locator-capture-\(getuid()).lock" }

    /// In-process circuit breaker for a WEDGED capture subsystem (Screen Recording denied to this binary,
    /// or `replayd` stuck). Each such call makes ScreenCaptureKit's one-shot hang or throw — and Apple's
    /// `SCShareableContent.current` LEAKS its internal continuation on that path (the "SWIFT TASK
    /// CONTINUATION MISUSE" print). `raceTimeout` frees the CALLER, but the op task is orphaned awaiting
    /// the dead call. In a short CLI that dies with the process; in the LONG-LIVED MCP engine / behavior
    /// watcher those orphans + leaked continuations ACCUMULATE without bound.
    ///
    /// The breaker stops that: after `trip` consecutive failures it OPENS — every capture fast-returns nil
    /// (no new op task spawned, so no new leak) for `cooldown` seconds, then lets exactly ONE half-open
    /// probe test recovery. A success closes it. Bounds lifetime orphans to a small constant per wedge
    /// episode instead of one every few seconds forever, and turns a multi-second stall into an instant
    /// honest "capture unavailable". (TCC re-grant requires an app restart anyway, which resets this.)
    public final class Circuit: @unchecked Sendable {
        private let lock = NSLock()
        private var consecutiveFailures = 0
        private var openUntil: Date?
        private let trip: Int
        private let cooldown: TimeInterval
        private let breakerFile: String
        public init(trip: Int = 3, cooldown: TimeInterval = 30, breakerFile: String? = nil) {
            self.trip = trip; self.cooldown = cooldown
            self.breakerFile = breakerFile ?? "/tmp/locator-capture-breaker-\(getuid())"
        }

        // CROSS-PROCESS open state: the wedge is in the shared system daemon (replayd), so the breaker
        // must be shared too. Several engines (e.g. Claude Desktop spawns more than one) each with a
        // private breaker would each re-hammer a wedged replayd on their first tries. A tiny file holds
        // the "open until" epoch; when ANY engine trips it, ALL engines fast-fail for the cooldown, so
        // replayd is left alone long enough to recover instead of being kept pegged by the fleet.
        private func sharedOpenUntil() -> Date? {
            guard let s = try? String(contentsOfFile: breakerFile, encoding: .utf8),
                  let t = TimeInterval(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            return Date(timeIntervalSince1970: t)
        }
        private func writeSharedOpen(_ until: Date?) {
            if let until { try? "\(until.timeIntervalSince1970)".write(toFile: breakerFile, atomically: true, encoding: .utf8) }
            else { try? FileManager.default.removeItem(atPath: breakerFile) }
        }

        /// When the breaker is OPEN (here or in any engine, via the shared file), the instant it will
        /// allow captures again — nil when closed. Read-only: lets a long-running frontend (the watch)
        /// NARRATE that perception is paused instead of silently resolving everything to "?".
        public func pausedUntil(now: Date = Date()) -> Date? {
            lock.lock(); defer { lock.unlock() }
            guard let until = openUntil ?? sharedOpenUntil(), now < until else { return nil }
            return until
        }

        /// May a capture be attempted now? False while the breaker is open — in THIS process or any other
        /// engine (shared file). When the cooldown has elapsed it clears the open state (half-open probe).
        public func allow(now: Date = Date()) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let until = openUntil ?? sharedOpenUntil()
            if let until {
                guard now >= until else { return false }   // still open (here or another engine) — skip
                openUntil = nil; writeSharedOpen(nil)      // cooldown elapsed → half-open: allow one probe
            }
            return true
        }

        /// A DELIBERATE fresh start clears the breaker — in-process and the shared file. Without this a
        /// brand-new serve inherited a stale pause from disk and sat blind for a cooldown it never earned,
        /// which reads exactly like a broken engine ("captures are PAUSED" on a process 2 seconds old).
        /// The protection is not lost: if replayd is still wedged, the next 3 probes re-open it honestly.
        public func reset() {
            lock.lock(); defer { lock.unlock() }
            consecutiveFailures = 0; openUntil = nil; writeSharedOpen(nil)
        }

        /// Record a capture outcome. `success` = ScreenCaptureKit RESPONDED (even if it found no window);
        /// failure = timed out or threw. Success closes the breaker; `trip` consecutive failures open it —
        /// and the open state is published to the shared file so the whole engine fleet backs off together.
        public func record(success: Bool, now: Date = Date()) {
            lock.lock()
            let wasOpen = (openUntil ?? sharedOpenUntil()) != nil
            if success {
                consecutiveFailures = 0; openUntil = nil; writeSharedOpen(nil)
            } else {
                consecutiveFailures += 1
                if consecutiveFailures >= trip {
                    let until = now.addingTimeInterval(cooldown)
                    openUntil = until; writeSharedOpen(until)
                }
            }
            let justOpened = !wasOpen && openUntil != nil
            lock.unlock()
            if justOpened {
                FileHandle.standardError.write(Data(
                    "[capture] subsystem unresponsive after \(trip) tries — pausing captures for \(Int(cooldown))s (shared across engines) so replayd can recover.\n".utf8))
            }
        }
    }

    /// The shared breaker guarding every ScreenCaptureKit one-shot in this process.
    public static let circuit = Circuit()

    static func log(_ s: String) {
        guard ProcessInfo.processInfo.environment["LOCATOR_DEBUG"] != nil else { return }
        FileHandle.standardError.write(Data("[gate \(getpid())] \(s)\n".utf8))
    }

    /// Run `body` while holding the cross-process capture lock (best-effort).
    public static func serialized<T: Sendable>(timeout: TimeInterval = 10.0,
                                               _ body: @Sendable () async throws -> T) async rethrows -> T {
        let fd = open(lockPath, O_CREAT | O_WRONLY, 0o644)
        var locked = false
        let t0 = Date()
        if fd >= 0 {
            let deadline = t0.addingTimeInterval(timeout)
            while true {
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
                if Date() >= deadline {
                    log("busy \(Int(timeout))s — proceeding UNLOCKED")
                    break
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
        if locked { log(String(format: "acquired after %.2fs", Date().timeIntervalSince(t0))) }
        defer {
            if fd >= 0 {
                if locked { flock(fd, LOCK_UN); log("released") }
                close(fd)
            }
        }
        return try await body()
    }
}
