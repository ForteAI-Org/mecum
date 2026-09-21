import Foundation

/// THE OBSERVATION STREAM (`ingest.ndjson`, issue 05).
///
/// Without this the Look and decay thresholds can never be earned. `transient 12`, `stale 150`,
/// `coincidence 30`, `transitionStale 300` (`UIBrain.Retention`) are counted in **observations of a
/// window** — not in frames, and not in days. A corpus that records frames but not observations can
/// sweep none of them, and those four are most of the map's re-derive list.
///
/// `ingestEpoch` rides along because it is what the 2026-09-06 brain-amnesia fix keyed decay to: a
/// take that loses it cannot reproduce a decay bug, which is the one bug this stream exists to catch.
public struct IngestRecord: Codable, Sendable, Equatable {
    public let ts: Date
    public let observationBlock: Int
    public let stateKey: String
    public let windowHandle: UInt32?
    public let anchorKeys: [String]
    public let groups: [String]
    public let transitions: [String]
    public let ingestEpoch: Int

    public init(ts: Date, observationBlock: Int, stateKey: String, windowHandle: UInt32?,
                anchorKeys: [String], groups: [String], transitions: [String], ingestEpoch: Int) {
        self.ts = ts; self.observationBlock = observationBlock; self.stateKey = stateKey
        self.windowHandle = windowHandle; self.anchorKeys = anchorKeys; self.groups = groups
        self.transitions = transitions; self.ingestEpoch = ingestEpoch
    }
}

/// ONE TURN, AS THE HARNESS REPLAYS IT (`session.ndjson`, issue 06).
///
/// `rounds` is `Int?` for the same reason it is on a `Turn`: `nil` means UNKNOWN (nobody counted —
/// an MCP-driven turn has no phrase and no loop of ours), `0` means the model was never asked and is
/// the no-model share's numerator. Booking an uncounted turn as `0` would inflate the headline the
/// whole effort is judged by.
public struct SessionRecord: Codable, Sendable, Equatable {
    public let ts: Date
    public let phrase: String
    public let tools: [LocatorMemory.TurnTool]
    public let rounds: Int?
    public let imitated: Bool
    public let answer: String?
    public let ok: Bool
    public let app: String?
    /// Set on the turn that opens a task. Rounds-per-*task* needs a task boundary, and a replay must
    /// not have to guess where one flow ended and the next began.
    public let taskMark: String?

    public init(ts: Date, phrase: String, tools: [LocatorMemory.TurnTool], rounds: Int?, imitated: Bool,
                answer: String?, ok: Bool, app: String?, taskMark: String? = nil) {
        self.ts = ts; self.phrase = phrase; self.tools = tools; self.rounds = rounds
        self.imitated = imitated; self.answer = answer; self.ok = ok; self.app = app; self.taskMark = taskMark
    }
}

/// INPUT EVENTS (`events.ndjson`, issue 06) — by CLASS, never by content.
///
/// The redaction law is enforced **by construction** here rather than by a filter: there is nowhere in
/// this type to put typed text. A `key` event can only ever be `.returnKey` or `.escape`, because those
/// two are the ones ticket 04 made Look triggers; every other keystroke is exactly the thing the law
/// forbids keeping, so it has no representation at all. A filter can be forgotten; a missing field
/// cannot be filled in by accident.
public struct InputEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case click, rightClick, doubleClick, scrollEnd, returnKey, escape, focusChange
    }
    public let ts: Date
    public let kind: Kind
    public let windowHandle: UInt32?
    /// Where, in WINDOW-NORMALIZED coordinates — a disambiguation hint for the replay, never an aim
    /// point, and meaningless outside the window it was recorded in.
    public let pos: [Double]?

    public init(ts: Date, kind: Kind, windowHandle: UInt32?, pos: [Double]? = nil) {
        self.ts = ts; self.kind = kind; self.windowHandle = windowHandle; self.pos = pos
    }
}
