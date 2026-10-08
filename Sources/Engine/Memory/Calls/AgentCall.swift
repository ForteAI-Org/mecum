//
//  AgentCall.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import PerceptionCore

// `SceneEffect` is PerceptionCore's: `ObservedEffect` keeps its family and encoding as text.

/// AgentTool is one of the tools the app's MCP adapter exposes, by the name a model calls it with.
/// A call of any of them is an `action` event: the call happened, not that a gesture landed. The six
/// input tools are calls too; an `input` event is a gesture the Watcher saw.
public enum AgentTool: String, Sendable, Equatable, Hashable, CaseIterable {

    case status
    case windows
    case apps
    case openSession  = "open_session"
    case observe
    case act
    case select
    case typeText     = "type_text"
    case insertText   = "insert_text"
    case pressKey     = "press_key"
    case scroll
    case drag
    case contextMenu  = "context_menu"
    case batch
    case menu
    case press
    case closeSession = "close_session"

    /// Whether the tool requires the current session: every tool but the three read-only listings
    /// and `open_session`. The session a call names is its event's `sessionID`.
    public var takesSession: Bool {
        switch self {
            case .status, .windows, .apps, .openSession: false
            default                                    : true
        }
    }

    /// Whether the tool may be a step of a batch: `act`, `select` and the six inputs.
    public var isBatchStep: Bool {
        switch self {
            case .act, .select, .typeText, .insertText, .pressKey, .scroll, .drag, .contextMenu: true
            default                                                                            : false
        }
    }
}

/// AgentKeyModifier is a modifier `press_key` holds, by the tool's own token.
public enum AgentKeyModifier: String, Sendable, Equatable, Hashable, CaseIterable {
    case cmd, shift, opt, ctrl

    /// The modifiers of a chord, in the order the tool's definition lists them.
    public static func ordered(_ modifiers: KeyModifiers) -> [AgentKeyModifier] {
        var tokens: [AgentKeyModifier] = []
        if modifiers.contains(.command) { tokens.append(.cmd) }
        if modifiers.contains(.shift)   { tokens.append(.shift) }
        if modifiers.contains(.option)  { tokens.append(.opt) }
        if modifiers.contains(.control) { tokens.append(.ctrl) }
        return tokens
    }
}

/// AgentScrollDirection is the wheel's direction `scroll` names; there is no horizontal one.
public enum AgentScrollDirection: String, Sendable, Equatable, Hashable, CaseIterable {
    case up, down
}

/// AgentDragEnd is where a drag ends: on another target, or at an offset in points.
public enum AgentDragEnd: Sendable {
    case target(String)
    case offset(dx: Double, dy: Double)
}

/// AgentCallRequest is one call's arguments as the tool decoded them, normalized once: a default
/// the decoder fills in (`act`'s verb, `type_text`'s replace, `press_key`'s count, `scroll`'s lines,
/// a drag offset's missing axis) is written explicitly, and an absent optional is absent. Nothing
/// is recomputed when the call is read back or offered again. The session a call names is not an
/// argument: it is the event's `sessionID`. A batch's steps are not arguments either: each is a call
/// of its own, a child event of the batch.
///
/// The type has no `==`: two requests are compared with `isExactly(_:)`, texts byte for byte.
public enum AgentCallRequest: Sendable {

    case status
    case windows(app: String?)
    case apps(query: String?)
    case openSession(app: String, window: String?)
    case observe(full: Bool)
    case act(target: String, verb: ActionVerb, value: ControlState?, section: String?)
    case select(control: String, item: String)
    case typeText(target: String, text: String, section: String?, replace: Bool)
    case insertText(text: String, expectedValue: String?)
    case pressKey(key: KeyChord.Name, modifiers: [AgentKeyModifier], count: Int)
    case scroll(direction: AgentScrollDirection, lines: Int, target: String?, section: String?)
    case drag(from: String, to: AgentDragEnd, section: String?)
    case contextMenu(target: String, item: String, section: String?)
    case batch
    case menu(path: String)
    case press(button: String)
    case closeSession

    public var tool: AgentTool {
        switch self {
            case .status      : .status
            case .windows     : .windows
            case .apps        : .apps
            case .openSession : .openSession
            case .observe     : .observe
            case .act         : .act
            case .select      : .select
            case .typeText    : .typeText
            case .insertText  : .insertText
            case .pressKey    : .pressKey
            case .scroll      : .scroll
            case .drag        : .drag
            case .contextMenu : .contextMenu
            case .batch       : .batch
            case .menu        : .menu
            case .press       : .press
            case .closeSession: .closeSession
        }
    }

    /// The request of an input as the tool's decoder builds it (`InputRequest.Input`), with the
    /// section it passes: a scroll's signed lines become a direction and a count, a chord's
    /// modifiers their tokens in the definition's order, a key its name.
    public static func input(_ input: InputRequest.Input, section: String?) -> AgentCallRequest {
        switch input {
            case .typeText(let text, let target, let replacing):
                return .typeText(target: target, text: text, section: section, replace: replacing)
            case .insertText(let text, let expecting):
                return .insertText(text: text, expectedValue: expecting)
            case .pressKey(let chord, let times):
                return .pressKey(key: chord.key, modifiers: AgentKeyModifier.ordered(chord.modifiers), count: times)
            case .scroll(let lines, let target):
                return .scroll(direction: lines > 0 ? .up : .down, lines: abs(lines), target: target, section: section)
            case .drag(let from, .target(let to)):
                return .drag(from: from, to: .target(to), section: section)
            case .drag(let from, .offset(let dx, let dy)):
                return .drag(from: from, to: .offset(dx: dx, dy: dy), section: section)
            case .contextMenu(let target, let item):
                return .contextMenu(target: target, item: item, section: section)
        }
    }

    /// Refuses a request the tools could not have decoded in a shape the contract keeps: `value`
    /// without `set_toggle` or `set_toggle` without on/off, a count or a line number below one, an
    /// offset that is not a finite number, a modifier twice. The tools' upper limits (20 presses,
    /// 50 lines, 5000 points) are the product's, not the store's, and are not repeated here.
    public func validate() throws {
        func refuse(_ invalidity: AgentCallError.Invalidity) -> AgentCallError { .invalidRequest(invalidity) }
        switch self {
            case .act(_, let verb, let value, _):
                if verb == .setToggle, value == nil { throw refuse(.toggleWithoutValue) }
                if verb != .setToggle, value != nil { throw refuse(.valueWithoutToggle) }
                if let value, value != .on, value != .off { throw refuse(.valueNotOnOff) }
            case .pressKey(_, let modifiers, let count):
                if Set(modifiers).count != modifiers.count { throw refuse(.repeatedModifier) }
                if count < 1 { throw refuse(.notPositive(argument: "count")) }
            case .scroll(_, let lines, _, _):
                if lines < 1 { throw refuse(.notPositive(argument: "lines")) }
            case .drag(_, .offset(let dx, let dy), _):
                if !dx.isFinite { throw refuse(.notFinite(argument: "dx")) }
                if !dy.isFinite { throw refuse(.notFinite(argument: "dy")) }
            default:
                break
        }
    }

    /// Whether the other request is this one exactly: the same tool and the same arguments, texts
    /// byte for byte, numbers as IEEE values (so `-0.0` and `0.0` are one offset), lists in order.
    public func isExactly(_ other: AgentCallRequest) -> Bool {
        tool == other.tool && BrainArgument.exactlyEqual(arguments, other.arguments)
    }
}

/// AgentCallRecord is a call as a producer offers it: its event and its request. The event is an
/// `action`; a tool that takes the session names it in the event's `sessionID`. A batch step is
/// offered only with its batch (`AgentCallStoring.record(batch:steps:)`), as a child event.
public struct AgentCallRecord: Sendable {

    public let event: MemoryEventRecord
    public let request: AgentCallRequest

    public init(event: MemoryEventRecord, request: AgentCallRequest) throws {
        try event.validate()
        guard event.kind == .action else { throw AgentCallError.invalidRequest(.notAnAction) }
        if request.tool.takesSession, event.sessionID == nil { throw AgentCallError.invalidRequest(.missingSession) }
        try request.validate()
        self.event   = event
        self.request = request
    }
}

/// AgentCallStatus is a call's execution state, the store's vocabulary. `completed` means the call
/// concluded, not that a task or a step succeeded; `skipped` is a batch step never attempted.
public enum AgentCallStatus: String, Sendable, Equatable, Hashable, CaseIterable {

    case planned, started, completed, failed, cancelled, interrupted, skipped

    public var isTerminal: Bool { self != .planned && self != .started }

    /// The states this one may move to: a planned call starts, is skipped or is cancelled; a started
    /// one completes, fails, is cancelled or is interrupted. A terminal state moves nowhere.
    public var next: Set<AgentCallStatus> {
        switch self {
            case .planned: [.started, .skipped, .cancelled]
            case .started: [.completed, .failed, .cancelled, .interrupted]
            default      : []
        }
    }
}

/// AgentCallResult is what a concluded call answered, as far as this contract represents it:
///
/// - `outcome`: an action's or an input's `ActOutcome` kind and message, kept with its own
///   meaning (`honest_miss`, `ambiguous`, `acted_unverified`, `acted_noop` are not failures and not
///   successes);
/// - `batch`: a batch that ran to its end or stopped, with the steps it attempted and verified,
///   distinct from the batch call's own status, and always the summary its steps allow under the
///   current producer: `found_acted` is accepted, `acted_noop` only for `set_toggle`, and the first
///   other outcome or error stops the batch, its later steps skipped;
/// - `closed`: what `close_session` said;
/// - `error`: the error a failed call threw, as the tool reported it;
/// - `status`: what `status` answered (`StatusResult`: the session and the three permissions);
/// - `listing`: what `windows` or `apps` answered (`ListingResult`: the applications in order, their
///   windows in order, the count left out of the answer);
/// - `observation`: what `open_session` or `observe` answered (`ObservationResult`: the session, its
///   revision, the instant, and the real sample the scene was captured as; the scene's text is a
///   rendering of that sample, not a second fact).
///
/// Every listing and observation is typed rows, never a dump. The type has no `==`: results are
/// compared with `isExactly(_:)`, texts byte for byte.
public enum AgentCallResult: Sendable {
    case outcome(ActOutcomeKind, message: String)
    case batch(stopped: Bool, attempted: Int, verified: Int)
    case closed(message: String)
    case error(message: String)
    case status(StatusResult)
    case listing(ListingResult)
    case observation(ObservationResult)

    public func isExactly(_ other: AgentCallResult) -> Bool {
        switch (self, other) {
            case (.outcome(let a, let m), .outcome(let b, let n)): a == b && m.utf8.elementsEqual(n.utf8)
            case (.batch(let s, let a, let v), .batch(let t, let b, let w)): s == t && a == b && v == w
            case (.closed(let m), .closed(let n)), (.error(let m), .error(let n)): m.utf8.elementsEqual(n.utf8)
            case (.status(let a), .status(let b)): a.isExactly(b)
            case (.listing(let a), .listing(let b)): a.isExactly(b)
            case (.observation(let a), .observation(let b)): a.isExactly(b)
            default: false
        }
    }
}

/// AgentCallProgress is one state a call reaches, as its producer reports it: the status, the
/// result a concluded call answered, the instant it started, the instant it ended and how long
/// the tool ran. `planned` carries no instant; `started` carries the calendar instant the tool was
/// about to run, when the producer reports it (the producers of this build always do); every
/// terminal state carries its calendar end; a state reached from `started` may carry the duration
/// of the run, measured on the producer's monotonic clock from the start to the end, never as a
/// difference of calendar instants (which may run backwards); a completed call carries the result
/// its tool represents, a failed one its error; a concluded action or input may carry the effect
/// the engine observed.
public struct AgentCallProgress: Sendable {

    public let status: AgentCallStatus
    public let result: AgentCallResult?
    public let startedAtMS: Int64?
    public let endedAtMS: Int64?
    public let durationMS: Int64?
    public let observedEffect: ObservedEffect?

    public init(
        _ status      : AgentCallStatus,
        result        : AgentCallResult? = nil,
        startedAtMS   : Int64? = nil,
        endedAtMS     : Int64? = nil,
        durationMS    : Int64? = nil,
        observedEffect: ObservedEffect? = nil
    ) {
        self.status         = status
        self.result         = result
        self.startedAtMS    = startedAtMS
        self.endedAtMS      = endedAtMS
        self.durationMS     = durationMS
        self.observedEffect = observedEffect
    }

    public static let started = AgentCallProgress(.started)

    /// A start at this calendar instant, which the row keeps as `started_at_ms`.
    public static func started(atMS instant: Int64) -> AgentCallProgress {
        AgentCallProgress(.started, startedAtMS: instant)
    }

    /// The states a duration may be reported for: the ones reached from `started`.
    public static let timedStatuses: Set<AgentCallStatus> = [.completed, .failed, .cancelled, .interrupted]

    /// Refuses a progress the tool could not report: an instant on a state that has none or none on
    /// one that needs it, a start on a state other than `started`, a duration on a state not reached
    /// from `started` or a negative one, a result its tool does not represent in that state, an
    /// observed effect on anything but a concluded action or input, a listing or an observation
    /// whose rows do not fit their kind, or batch counts that are negative or verify more than they
    /// attempted.
    public func validate(for tool: AgentTool) throws {
        func refuse(_ invalidity: AgentCallError.Invalidity) -> AgentCallError { .invalidProgress(invalidity) }
        if status.isTerminal != (endedAtMS != nil) { throw refuse(status.isTerminal ? .endMissing : .endForbidden) }
        if startedAtMS != nil, status != .started { throw refuse(.startForbidden) }
        if let durationMS {
            guard Self.timedStatuses.contains(status) else { throw refuse(.durationForbidden) }
            guard durationMS >= 0 else { throw refuse(.durationNegative) }
        }
        if observedEffect != nil, !(status == .completed && tool.isBatchStep) { throw refuse(.effectForbidden) }
        let expected: ExpectedResult
        switch (status, tool) {
            case (.completed, .act), (.completed, .select), (.completed, .typeText), (.completed, .insertText),
                 (.completed, .pressKey), (.completed, .menu), (.completed, .press),
                 (.completed, .scroll), (.completed, .drag), (.completed, .contextMenu):
                expected = .outcome
            case (.completed, .batch)       : expected = .batch
            case (.completed, .closeSession): expected = .closed
            case (.completed, .status)      : expected = .status
            case (.completed, .windows)     : expected = .listing(.windows)
            case (.completed, .apps)        : expected = .listing(.apps)
            case (.completed, .openSession), (.completed, .observe):
                expected = .observation
            case (.failed, _)               : expected = .error
            default                         : expected = .none
        }
        switch (expected, result) {
            case (.none, nil), (.outcome, .outcome?), (.closed, .closed?), (.error, .error?), (.status, .status?):
                break
            case (.status, nil), (.listing, nil), (.observation, nil):
                // A concluded listing or scene whose typed rows the producer could not record: an explicit
                // gap, said by the producer, never a dump in their place.
                break
            case (.batch, .batch(_, let attempted, let verified)?):
                if attempted < 0 || verified < 0 || verified > attempted { throw refuse(.batchCounts) }
            case (.listing(let kind), .listing(let listing)?):
                guard listing.kind == kind else { throw refuse(.resultMismatch) }
                if let problem = listing.problem { throw refuse(.listingShape(problem)) }
            case (.observation, .observation(let observation)?):
                if let problem = observation.problem { throw refuse(.observationShape(problem)) }
            case (.none, _?):
                throw refuse(.resultForbidden)
            default:
                throw refuse(.resultMismatch)
        }
    }

    private enum ExpectedResult: Equatable { case none, outcome, batch, closed, error, status, listing(ListingResult.Kind), observation }

    /// Whether the other progress reports this one exactly: status, result, instants, duration and effect.
    public func isExactly(_ other: AgentCallProgress) -> Bool {
        guard status == other.status, endedAtMS == other.endedAtMS, startedAtMS == other.startedAtMS,
              durationMS == other.durationMS else { return false }
        switch (observedEffect, other.observedEffect) {
            case (nil, nil)      : break
            case (let a?, let b?): guard a.isExactly(b) else { return false }
            default              : return false
        }
        switch (result, other.result) {
            case (nil, nil)      : return true
            case (let a?, let b?): return a.isExactly(b)
            default              : return false
        }
    }

    /// What offering this progress does to a call stored at `stored`: `true` when it moves the call,
    /// `false` when it is the stored state again (a retry). A state the call may not move to is an
    /// `invalidTransition`; a terminal state other than the stored one, or the stored terminal state
    /// with another result or instant, is a conflict, as two contents under one identity are.
    public func decision(after stored: AgentCallProgress, eventID: String) throws -> Bool {
        if stored.status == status {
            if !status.isTerminal || stored.isExactly(self) { return false }
            throw AgentCallError.conflictingEnd(eventID: eventID, stored: stored.status, offered: status)
        }
        if stored.status.next.contains(status) { return true }
        if stored.status.isTerminal, status.isTerminal {
            throw AgentCallError.conflictingEnd(eventID: eventID, stored: stored.status, offered: status)
        }
        throw AgentCallError.invalidTransition(eventID: eventID, from: stored.status, to: status)
    }
}

/// AgentCallTransition is one call moved to one state: the unit `AgentCallStoring.advance` applies,
/// several at once in one transaction when a producer's step needs them together.
public struct AgentCallTransition: Sendable {

    public let eventID: String
    public let progress: AgentCallProgress

    public init(_ eventID: String, _ progress: AgentCallProgress) {
        self.eventID  = eventID
        self.progress = progress
    }
}

/// AgentCall is a stored call read back: its event, its request, the contract version it was
/// recorded under, where it stands, the calendar instant it started (kept whatever state it
/// reached since, nil for a call that never started or whose producer reported no start) and its
/// local order (the order the store wrote the events in, not a causal order between producers). A
/// batch carries the number of steps it was given. How long the tool ran is the progress's
/// `durationMS`, the producer's monotonic measure: the calendar instants are the chronology and
/// are never subtracted.
public struct AgentCall: Sendable {

    public let localOrder: Int64
    public let event: MemoryEventRecord
    public let request: AgentCallRequest
    public let contractVersion: Int
    public let progress: AgentCallProgress
    public let requestedSteps: Int?
    public let startedAtMS: Int64?

    public init(localOrder: Int64, event: MemoryEventRecord, request: AgentCallRequest, contractVersion: Int,
                progress: AgentCallProgress, requestedSteps: Int?, startedAtMS: Int64? = nil) {
        self.localOrder      = localOrder
        self.event           = event
        self.request         = request
        self.contractVersion = contractVersion
        self.progress        = progress
        self.requestedSteps  = requestedSteps
        self.startedAtMS     = startedAtMS
    }

    /// How long the tool ran, in milliseconds, as the producer measured it on its monotonic clock;
    /// nil when the call never ran or its producer reported none.
    public var durationMS: Int64? { progress.durationMS }
}

/// AgentCallContract is the versioned contract of a call's stored form: version 1 admits the
/// arguments `AgentCallArguments` lists for each tool and the result columns `AgentCallResult`
/// maps; anything else is refused on the way in and on the way out.
public enum AgentCallContract {
    public static let version = 1
}

/// AgentCallError is a call the store refuses to write, or a stored call it refuses to read.
public enum AgentCallError: Error, Sendable, Equatable {

    /// A request or a record no store should be asked to write.
    case invalidRequest(Invalidity)

    /// A progress its tool could not report.
    case invalidProgress(Invalidity)

    /// A batch offered with steps that are not its steps.
    case invalidBatch(Invalidity)

    /// A call moved to a state it may not reach from the stored one: a regression or a skip.
    case invalidTransition(eventID: String, from: AgentCallStatus, to: AgentCallStatus)

    /// A concluded call offered another end: another terminal state, or the same with another
    /// result or instant.
    case conflictingEnd(eventID: String, stored: AgentCallStatus, offered: AgentCallStatus)

    /// A transition for a call the store does not hold.
    case missingCall(eventID: String)

    /// A batch step started before its batch.
    case stepBeforeBatch(eventID: String)

    /// A batch concluded with a summary its steps do not allow under the current producer: a step
    /// still open, cancelled or interrupted, a step skipped before the stop or run after it, or a
    /// stop, attempted or verified count other than the steps give.
    case batchNotSettled(eventID: String)

    /// A stored call under a contract version this build does not read.
    case unsupportedContractVersion(eventID: String, version: Int)

    /// A stored call whose rows break the contract.
    case malformedCall(eventID: String, malformation: Malformation)

    public enum Invalidity: Sendable, Equatable {
        case notAnAction
        case missingSession
        case toggleWithoutValue
        case valueWithoutToggle
        case valueNotOnOff
        case repeatedModifier
        case notPositive(argument: String)
        case notFinite(argument: String)
        case stepOutsideBatch
        case batchOutsideBatchRecord
        case batchWithoutSteps
        case notABatch
        case notABatchStep(position: Int, tool: AgentTool)
        case stepParent(position: Int)
        case stepContext(position: Int, field: String)
        case repeatedStep(position: Int)
        case endMissing
        case endForbidden
        case startForbidden
        case durationForbidden
        case durationNegative
        case effectForbidden
        /// An observed effect whose parts do not fit its family: a title without `windowTitleChanged`,
        /// states without `stateFlip`, labels under a scalar family, or a family the vocabulary lacks.
        case effectShape(String)
        case resultForbidden
        case resultMismatch
        case batchCounts
        /// A listing whose rows do not fit its kind (`ListingResult.problem`).
        case listingShape(String)
        /// An observation result with an empty session or a sample key that is not a current primary.
        case observationShape(String)
    }

    public enum Malformation: Sendable, Equatable {
        case unknownTool(String)
        case unknownStatus(String)
        case notAnAction
        case forbiddenArgument(String)
        case missingArgument(String)
        case duplicateArgument(String, position: Int)
        case argumentKindMismatch(String)
        case positionsNotContiguous(String)
        case unknownCode(argument: String, code: String)
        case incompatibleArguments(String)
        case invalidValue(String)
        case forbiddenColumn(String)
        case resultShape(String)
    }

    /// An observation result that names a sample the store does not hold: the producer must record
    /// the sample before the result that points to it.
    case missingSample(eventID: String, sample: CaptureSampleKey)
}
