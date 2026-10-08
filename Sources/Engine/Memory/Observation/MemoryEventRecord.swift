//
//  MemoryEventRecord.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import PerceptionCore

/// MemoryEventSource is who produced an event: the app's worker, the command line, an external MCP
/// client served by the app, the Watcher or the system itself. The raw values are the ones the
/// living memory stores. An external client learns into the same archive as the app; its source
/// keeps its calls apart from the workers'.
public enum MemoryEventSource: String, Sendable, Equatable, Hashable, CaseIterable {
    case app, cli, mcp, watcher, system
}

/// MemoryEventKind is what an event is a fact of: a tool invocation, an input the Watcher saw, an
/// observation taken on its own, a verification, or a diagnostic. `action` means the call happened,
/// not that a gesture landed.
public enum MemoryEventKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case action, input, observation, verification, diagnostic
}

/// EventCaptureStatus is the summary an event carries about its samples: not applicable when the
/// event takes none, else the worst completeness among the samples recorded so far. It is the one
/// mutable column of an event; the per-sample quality lives on each sample.
public enum EventCaptureStatus: String, Sendable, Equatable, Hashable, CaseIterable {

    case notApplicable = "not_applicable"
    case complete
    case partial
    case failed
    case unknown

    /// The summary of a set of sample completenesses: `failed` if any failed, else `partial` if
    /// any is partial, else `unknown` if any is unknown, else `complete`. An empty set is
    /// `notApplicable`.
    public static func summary(of samples: [CaptureQuality.Completeness]) -> EventCaptureStatus {
        guard !samples.isEmpty else { return .notApplicable }
        if samples.contains(.failed) { return .failed }
        if samples.contains(.partial) { return .partial }
        if samples.contains(.unknown) { return .unknown }
        return .complete
    }
}

/// AppContextIdentity names the application an event concerns and the context it was observed in.
/// A version or a locale the producer does not know stays `nil`, which the store keeps as its own
/// "unknown" marker, the empty text; it is never guessed from another event. That marker is the
/// one place where empty text and NULL mean the same thing, and `stored` says so explicitly.
public struct AppContextIdentity: Sendable, Equatable, Hashable {

    public let bundleID: String
    public let version: String?
    public let locale: String?

    public init(bundleID: String, version: String? = nil, locale: String? = nil) {
        self.bundleID = bundleID
        self.version  = version
        self.locale   = locale
    }

    /// The context as the store keeps it: an empty version or locale is the unknown marker, so it
    /// reads back as `nil`. Two contexts that differ only by that marker are the same stored row.
    public var stored: AppContextIdentity {
        AppContextIdentity(
            bundleID: bundleID,
            version : version.flatMap { $0.isEmpty ? nil : $0 },
            locale  : locale.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

/// MemoryEventRecord is one fact of the living memory as a producer offers it and as a reader gets
/// it back: its identity (`eventID`, or the source's own key), its source and stream, its kind, the
/// application and context it concerns when known, and when it happened. Identity and context are
/// immutable once stored; `captureStatus` is the one summary that moves as samples arrive. Two
/// offers under one identity with different content are a conflict, never an update: the
/// comparison is `hasSameImmutableContent(as:)`, typed and exact, NULL apart from empty text, with
/// the app context's unknown marker as the one declared exception.
public struct MemoryEventRecord: Sendable, Equatable {

    public var eventID: String
    public var source: MemoryEventSource
    public var streamID: String
    public var sourceKey: String?
    public var traceID: String?
    public var sessionID: String?
    public var parentEventID: String?
    public var parentPosition: Int?
    public var kind: MemoryEventKind
    public var app: AppContextIdentity?
    public var occurredAtMS: Int64
    public var monotonicNS: Int64?
    public var captureStatus: EventCaptureStatus

    /// The call an `observation` was taken for, when a session observed on its own right after a
    /// call that could not name the application when it was planned (`open_session`): a durable
    /// reference to that call's event, apart from a batch's parent (an observation is no step). Nil
    /// for every other event, and never on an event that is not an observation.
    public var originEventID: String?

    public init(
        eventID       : String,
        source        : MemoryEventSource,
        streamID      : String,
        sourceKey     : String? = nil,
        traceID       : String? = nil,
        sessionID     : String? = nil,
        parentEventID : String? = nil,
        parentPosition: Int? = nil,
        kind          : MemoryEventKind,
        app           : AppContextIdentity? = nil,
        occurredAtMS  : Int64,
        monotonicNS   : Int64? = nil,
        captureStatus : EventCaptureStatus = .unknown,
        originEventID : String? = nil
    ) {
        self.eventID        = eventID
        self.source         = source
        self.streamID       = streamID
        self.sourceKey      = sourceKey
        self.traceID        = traceID
        self.sessionID      = sessionID
        self.parentEventID  = parentEventID
        self.parentPosition = parentPosition
        self.kind           = kind
        self.app            = app
        self.occurredAtMS   = occurredAtMS
        self.monotonicNS    = monotonicNS
        self.captureStatus  = captureStatus
        self.originEventID  = originEventID
    }

    /// Refuses a record no store should be asked to write.
    public func validate() throws {
        if eventID.isEmpty { throw ObservationContractError.invalidRecord(.emptyEventID) }
        if streamID.isEmpty { throw ObservationContractError.invalidRecord(.emptyStreamID) }
        if let app, app.bundleID.isEmpty { throw ObservationContractError.invalidRecord(.emptyBundleID) }
        if (parentEventID == nil) != (parentPosition == nil) {
            throw ObservationContractError.invalidRecord(.parentWithoutPosition)
        }
        if let originEventID {
            if kind != .observation { throw ObservationContractError.invalidRecord(.originOnNonObservation) }
            if originEventID.isEmpty || originEventID.utf8.elementsEqual(eventID.utf8) {
                throw ObservationContractError.invalidRecord(.originIsSelf)
            }
        }
    }

    /// ImmutableContent is everything a stored event may never change: every field but the mutable
    /// `captureStatus`, typed, with the app context as the store keeps it. Two contents are equal
    /// only when every text is the same bytes, as the file compares them: Swift's own `String`
    /// equality would call two canonically equivalent ids, streams or bundles the same fact.
    public struct ImmutableContent: Sendable, Equatable {

        public let eventID: String
        public let source: MemoryEventSource
        public let streamID: String
        public let sourceKey: String?
        public let traceID: String?
        public let sessionID: String?
        public let parentEventID: String?
        public let parentPosition: Int?
        public let kind: MemoryEventKind
        public let app: AppContextIdentity?
        public let occurredAtMS: Int64
        public let monotonicNS: Int64?
        public let originEventID: String?

        public static func == (lhs: ImmutableContent, rhs: ImmutableContent) -> Bool {
            func same(_ a: String?, _ b: String?) -> Bool {
                switch (a, b) {
                    case (nil, nil)       : true
                    case (let a?, let b?) : a.utf8.elementsEqual(b.utf8)
                    default               : false
                }
            }
            return same(lhs.eventID, rhs.eventID) && lhs.source == rhs.source && same(lhs.streamID, rhs.streamID)
                && same(lhs.sourceKey, rhs.sourceKey) && same(lhs.traceID, rhs.traceID) && same(lhs.sessionID, rhs.sessionID)
                && same(lhs.parentEventID, rhs.parentEventID) && lhs.parentPosition == rhs.parentPosition
                && lhs.kind == rhs.kind && (lhs.app == nil) == (rhs.app == nil)
                && same(lhs.app?.bundleID, rhs.app?.bundleID) && same(lhs.app?.version, rhs.app?.version)
                && same(lhs.app?.locale, rhs.app?.locale)
                && lhs.occurredAtMS == rhs.occurredAtMS && lhs.monotonicNS == rhs.monotonicNS
                && same(lhs.originEventID, rhs.originEventID)
        }
    }

    /// The immutable content, for the exact comparison two offers under one identity are decided by.
    public var immutableContent: ImmutableContent {
        ImmutableContent(
            eventID       : eventID,
            source        : source,
            streamID      : streamID,
            sourceKey     : sourceKey,
            traceID       : traceID,
            sessionID     : sessionID,
            parentEventID : parentEventID,
            parentPosition: parentPosition,
            kind          : kind,
            app           : app?.stored,
            occurredAtMS  : occurredAtMS,
            monotonicNS   : monotonicNS,
            originEventID : originEventID
        )
    }

    /// Whether the other record carries exactly this one's immutable content: the typed comparison
    /// that decides `alreadyApplied` apart from a conflict. `captureStatus` is left out because it
    /// is the one column allowed to move.
    public func hasSameImmutableContent(as other: MemoryEventRecord) -> Bool {
        immutableContent == other.immutableContent
    }

    /// A digest of the immutable content for diagnostics and conflict reports, every field with its
    /// length and a NULL marker so a separator inside a value cannot stand for a field boundary.
    /// Never the decision: `hasSameImmutableContent(as:)` is.
    public var contentDigest: String {
        let content = immutableContent
        return StructuralDigest.fnv1a([
            content.source.rawValue, CanonicalText.field(content.streamID), CanonicalText.field(content.sourceKey),
            CanonicalText.field(content.traceID), CanonicalText.field(content.sessionID),
            CanonicalText.field(content.parentEventID), CanonicalText.field(content.parentPosition.map(String.init)),
            content.kind.rawValue, CanonicalText.field(content.app?.bundleID), CanonicalText.field(content.app?.version),
            CanonicalText.field(content.app?.locale), String(content.occurredAtMS),
            CanonicalText.field(content.monotonicNS.map(String.init)), CanonicalText.field(content.originEventID),
        ].joined(separator: "\u{1F}"))
    }
}
