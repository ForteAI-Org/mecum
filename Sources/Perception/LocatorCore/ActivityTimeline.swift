import Foundation

/// The activity timeline — the first slice of the symbolic-seeing design
/// (docs/codex/2026-08-11-symbolic-seeing-process-design.md): deterministic episode segmentation over
/// the existing interaction ledger. Shadow-mode by construction — it READS the spine and never acts.
/// No LLM anywhere in this file: titles are derived, boundaries carry their evidence ("idle 6m"),
/// and the whole projection is rebuilt from events on every query (nothing to migrate or go stale).

/// One event off the spine (a watcher observation or an agent act), typed for segmentation.
public struct ActivityEvent: Sendable, Equatable {
    public var ts: Date
    public var actor: String        // "user" | "agent"
    public var app: String          // bundle id
    public var appName: String      // display name when known, else bundle tail
    public var kind: String         // click | rightclick | focus | hover | scroll | scroll_end | act | run_menu | type | …
    public var section: String?
    public var label: String?       // element label only — never content
    public var verb: String?

    public init(ts: Date, actor: String, app: String, appName: String, kind: String,
                section: String? = nil, label: String? = nil, verb: String? = nil) {
        self.ts = ts; self.actor = actor; self.app = app; self.appName = appName
        self.kind = kind; self.section = section; self.label = label; self.verb = verb
    }
}

/// A run of same-app events with no long pause — the "step" tier of the hierarchy.
public struct ActivityStep: Sendable, Equatable {
    public var app: String
    public var appName: String
    public var events: [ActivityEvent]
    public var isInterruption: Bool = false   // short foreign-app detour folded into the surrounding task
    public var isGlue: Bool = false           // launcher/system surface (Dock, Spotlight) — task connective tissue
    public var start: Date { events.first?.ts ?? .distantPast }
    public var end: Date { events.last?.ts ?? .distantPast }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// The "task" tier: steps that belong to one stretch of intent, with the boundary that ENDED it.
public struct ActivityEpisode: Sendable, Equatable {
    public var steps: [ActivityStep]
    public var endReason: String?     // evidence for the boundary after this episode ("idle 6m", "switched to Slack") — nil while open
    public var start: Date { steps.first?.start ?? .distantPast }
    public var end: Date { steps.last?.end ?? .distantPast }
    /// The app this episode is ABOUT: the non-interruption, non-glue app with the most events
    /// (glue counts only when the episode holds nothing else).
    public var primaryApp: (bundle: String, name: String) {
        var counts: [String: (name: String, n: Int)] = [:]
        for s in steps where !s.isInterruption && !s.isGlue {
            counts[s.app, default: (s.appName, 0)].n += s.events.count
        }
        if counts.isEmpty {
            for s in steps { counts[s.app, default: (s.appName, 0)].n += s.events.count }
        }
        let best = counts.max { $0.value.n < $1.value.n }
        return best.map { ($0.key, $0.value.name) } ?? (steps.first?.app ?? "?", steps.first?.appName ?? "?")
    }
    public var eventCount: Int { steps.reduce(0) { $0 + $1.events.count } }
    public var hasAgentActivity: Bool { steps.contains { s in s.events.contains { $0.actor == "agent" } } }
    /// Derived, model-free title: dominant app + what was touched most.
    public var title: String {
        let labels = steps.filter { !$0.isInterruption && !$0.isGlue }.flatMap(\.events).compactMap(\.label)
        var freq: [String: Int] = [:]
        for l in labels where l.count > 1 { freq[l, default: 0] += 1 }
        let top = freq.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(3).map(\.key)
        return primaryApp.name + (top.isEmpty ? "" : " — " + top.joined(separator: ", "))
    }
}

/// Deterministic segmentation. Pure — every rule is a measurable threshold, every boundary keeps its
/// evidence, same events in ⇒ same timeline out.
public enum EpisodeSegmenter {
    public struct Tuning: Sendable {
        /// A pause longer than this inside one app still splits the STEP (a step is one burst of activity).
        public var stepGap: TimeInterval = 25
        /// A pause longer than this ends the TASK ("idle" boundary).
        public var taskGap: TimeInterval = 120
        /// A foreign-app detour at most this long, sandwiched between same-app steps, FOLDS into the
        /// task as an interruption (the Slack-ping case; also Resolve→Finder→Resolve mid-export).
        public var interruptionMax: TimeInterval = 90
        /// Launcher/system surfaces are the connective tissue BETWEEN tasks, never a task themselves:
        /// on the first real ledger, Dock clicks made "Dock" the primary app of half the timeline.
        /// Glue steps join whatever episode is open and can neither own nor split one.
        public var glueApps: Set<String> = ["com.apple.dock", "com.apple.spotlight",
                                            "com.apple.loginwindow", "com.apple.windowmanager"]
        public init() {}
    }

    /// Tier 1: same-app bursts.
    public static func steps(_ events: [ActivityEvent], tuning: Tuning = .init()) -> [ActivityStep] {
        var out: [ActivityStep] = []
        for e in events {
            if var last = out.last, last.app == e.app,
               e.ts.timeIntervalSince(last.end) < tuning.stepGap {
                last.events.append(e)
                out[out.count - 1] = last
            } else {
                out.append(ActivityStep(app: e.app, appName: e.appName, events: [e]))
            }
        }
        return out
    }

    /// Tier 2: fold sandwiched short detours, then group into episodes at idle gaps and app changes.
    public static func episodes(_ events: [ActivityEvent], tuning: Tuning = .init()) -> [ActivityEpisode] {
        var steps = Self.steps(events, tuning: tuning)
        for i in steps.indices where tuning.glueApps.contains(steps[i].app.lowercased()) {
            steps[i].isGlue = true
        }
        // Interruption fold — B is an interruption of A when A B A are adjacent, B is short, and the
        // pauses around B stay under the task gap (a long pause means A's task had already ended).
        for i in steps.indices.dropFirst().dropLast() {
            let (a, b, c) = (steps[i - 1], steps[i], steps[i + 1])
            if a.app == c.app, b.app != a.app, !b.isGlue, b.duration <= tuning.interruptionMax,
               b.start.timeIntervalSince(a.end) < tuning.taskGap,
               c.start.timeIntervalSince(b.end) < tuning.taskGap {
                steps[i].isInterruption = true
            }
        }
        var out: [ActivityEpisode] = []
        for step in steps {
            if var open = out.last, open.endReason == nil {
                let gap = step.start.timeIntervalSince(open.end)
                // An episode holding only glue so far belongs to whatever real app comes next.
                let settled = !open.steps.allSatisfy { $0.isInterruption || $0.isGlue }
                if gap >= tuning.taskGap {
                    open.endReason = "idle \(minutes(gap))"
                    out[out.count - 1] = open
                } else if !step.isInterruption, !step.isGlue, settled,
                          step.app != open.primaryApp.bundle {
                    open.endReason = "switched to \(step.appName)"
                    out[out.count - 1] = open
                } else {
                    open.steps.append(step)
                    out[out.count - 1] = open
                    continue
                }
            }
            out.append(ActivityEpisode(steps: [step], endReason: nil))
        }
        return out
    }

    static func minutes(_ t: TimeInterval) -> String {
        if t < 90 { return "\(Int(t))s" }
        if t < 5400 { return "\(Int((t / 60).rounded()))m" }
        let h = Int(t) / 3600
        return "\(h)h\(Int(t.truncatingRemainder(dividingBy: 3600)) / 60)m"
    }
}

/// Text rendering for `locator timeline` (and anything else that wants the hierarchy as lines).
public enum TimelineRenderer {
    static func hm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    public static func summaryLine(_ ep: ActivityEpisode, index: Int? = nil) -> String {
        let idx = index.map { String(format: "%3d  ", $0) } ?? ""
        let when = "\(hm(ep.start))–\(hm(ep.end))"
        let interruptions = ep.steps.filter(\.isInterruption).count
        var bits = [ep.eventCount == 1 ? "1 event" : "\(ep.eventCount) events"]
        if interruptions > 0 { bits.append("\(interruptions) interruption\(interruptions == 1 ? "" : "s")") }
        if ep.hasAgentActivity { bits.append("⚙ agent") }
        let boundary = ep.endReason.map { "  [\($0)]" } ?? "  [open]"
        return "\(idx)\(when)  \(ep.title)  (\(bits.joined(separator: ", ")))\(boundary)"
    }

    public static func detail(_ ep: ActivityEpisode) -> String {
        var lines = [summaryLine(ep)]
        for s in ep.steps {
            let mark = s.isInterruption ? "↳ interruption" : (s.isGlue ? "· glue" : "step")
            var kinds: [String: Int] = [:]
            for e in s.events { kinds[e.kind, default: 0] += 1 }
            let kindStr = kinds.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
            lines.append("  \(hm(s.start))  \(mark)  \(s.appName) — \(kindStr)")
            for e in s.events.suffix(80) {
                let who = e.actor == "agent" ? "⚙" : "•"
                let what = [e.verb, e.label.map { "\u{201C}\($0)\u{201D}" }, e.section.map { "in \($0)" }]
                    .compactMap(\.self).joined(separator: " ")
                lines.append("    \(hm(e.ts))  \(who) \(e.kind)\(what.isEmpty ? "" : " \(what)")")
            }
        }
        return lines.joined(separator: "\n")
    }
}
