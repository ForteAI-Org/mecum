//
//  AgentCallResults.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import PerceptionCore

/// ObservedEffect is the effect the engine attributed to a concluded action or input, as the call's
/// rows keep it: the family (`SceneEffect.family`) and, by family, the title a window changed to,
/// the states a control flipped from and to, or the labels of the rows a menu opened or the
/// elements that appeared or disappeared, each label its own row in order; a selection change is its
/// family alone. Built from the engine's
/// `SceneEffect` without passing through its text encoding, so two menus whose labels differ only
/// in where a separator falls stay two effects, texts keep their bytes, and an empty label is a
/// label. It is what was observed, not a verdict: a call with none observed none.
public struct ObservedEffect: Sendable, Equatable {

    public static let kinds: Set<String> = TransitionEffectRecord.kinds
    public static let listKinds: Set<String> = ["menuOpened", "elementsAppeared", "elementsDisappeared"]

    public let kind: String
    public let title: String?
    public let stateBefore: ControlState?
    public let stateAfter: ControlState?
    public let labels: [String]

    /// The effect as the engine attributed it.
    public init(_ effect: SceneEffect) {
        switch effect {
            case .windowTitleChanged(let title):
                self.init(family: effect.family, title: title, before: nil, after: nil, labels: [])
            case .stateFlip(let from, let to):
                self.init(family: effect.family, title: nil, before: from, after: to, labels: [])
            case .menuOpened(let labels), .elementsAppeared(let labels), .elementsDisappeared(let labels):
                self.init(family: effect.family, title: nil, before: nil, after: nil, labels: labels)
            case .textSelectionChanged:
                self.init(family: effect.family, title: nil, before: nil, after: nil, labels: [])
        }
    }

    private init(family: String, title: String?, before: ControlState?, after: ControlState?, labels: [String]) {
        self.kind        = family
        self.title       = title
        self.stateBefore = before
        self.stateAfter  = after
        self.labels      = labels
    }

    /// The effect read back from its columns and rows, refusing a shape its family does not have.
    public init(kind: String, title: String?, stateBefore: String?, stateAfter: String?, labels: [String]) throws {
        func refuse(_ what: String) -> AgentCallError { .invalidProgress(.effectShape(what)) }
        guard Self.kinds.contains(kind) else { throw refuse("kind \(kind)") }
        func state(_ code: String?) throws -> ControlState? {
            guard let code else { return nil }
            guard let state = ControlState(rawValue: code) else { throw refuse("state \(code)") }
            return state
        }
        let before = try state(stateBefore), after = try state(stateAfter)
        switch kind {
            case "windowTitleChanged":
                guard title != nil else { throw refuse("title missing") }
                guard before == nil, after == nil, labels.isEmpty else { throw refuse("title with states or labels") }
            case "stateFlip":
                guard before != nil, after != nil else { throw refuse("state missing") }
                guard title == nil, labels.isEmpty else { throw refuse("states with title or labels") }
            case "textSelectionChanged":
                guard title == nil, before == nil, after == nil, labels.isEmpty else {
                    throw refuse("selection change with title, states or labels")
                }
            default:
                guard title == nil, before == nil, after == nil else { throw refuse("labels with title or states") }
        }
        self.init(family: kind, title: title, before: before, after: after, labels: labels)
    }

    /// The engine's effect, rebuilt: the inverse of `init(_:)`, exact.
    public var sceneEffect: SceneEffect {
        switch kind {
            case "windowTitleChanged" : .windowTitleChanged(title: title ?? "")
            case "stateFlip"          : .stateFlip(from: stateBefore ?? .unknown, to: stateAfter ?? .unknown)
            case "elementsAppeared"    : .elementsAppeared(labels: labels)
            case "elementsDisappeared" : .elementsDisappeared(labels: labels)
            case "textSelectionChanged": .textSelectionChanged
            default                    : .menuOpened(labels: labels)
        }
    }

    /// Whether the other effect is this one exactly: family, states, title and labels byte for byte,
    /// labels in order.
    public func isExactly(_ other: ObservedEffect) -> Bool {
        kind.utf8.elementsEqual(other.kind.utf8) && stateBefore == other.stateBefore && stateAfter == other.stateAfter
            && CanonicalText.same(title, other.title) && labels.count == other.labels.count
            && zip(labels, other.labels).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }
}

/// StatusResult is what `status` answered: the session the host holds, or none, and the three
/// permissions as the host preflighted them.
public struct StatusResult: Sendable, Equatable {

    public let sessionID: String?
    public let screenRecording: Bool
    public let accessibility: Bool
    public let postEvent: Bool

    public init(sessionID: String?, screenRecording: Bool, accessibility: Bool, postEvent: Bool) {
        self.sessionID       = sessionID
        self.screenRecording = screenRecording
        self.accessibility   = accessibility
        self.postEvent       = postEvent
    }

    public func isExactly(_ other: StatusResult) -> Bool {
        CanonicalText.same(sessionID, other.sessionID) && screenRecording == other.screenRecording
            && accessibility == other.accessibility && postEvent == other.postEvent
    }
}

/// ListedWindow is one window `windows` listed: its window number and its title, nil when the
/// window server reported none (the answer shows an empty text; the row keeps the absence).
public struct ListedWindow: Sendable, Equatable {

    public let number: Int64
    public let title: String?

    public init(number: Int64, title: String?) {
        self.number = number
        self.title  = title
    }

    public func isExactly(_ other: ListedWindow) -> Bool {
        number == other.number && CanonicalText.same(title, other.title)
    }
}

/// ListedApplication is one application a listing answered. `windows` lists a running application
/// with its pid and its windows in order; `apps` lists a candidate with whether it runs, its version
/// and the folder that tells two of one name apart, each nil when the producer did not know it.
public struct ListedApplication: Sendable, Equatable {

    public let name: String
    public let bundleID: String
    public let pid: Int64?
    public let version: String?
    public let isRunning: Bool?
    public let location: String?
    public let windows: [ListedWindow]

    public init(name: String, bundleID: String, pid: Int64? = nil, version: String? = nil, isRunning: Bool? = nil,
                location: String? = nil, windows: [ListedWindow] = []) {
        self.name      = name
        self.bundleID  = bundleID
        self.pid       = pid
        self.version   = version
        self.isRunning = isRunning
        self.location  = location
        self.windows   = windows
    }

    public func isExactly(_ other: ListedApplication) -> Bool {
        name.utf8.elementsEqual(other.name.utf8) && bundleID.utf8.elementsEqual(other.bundleID.utf8) && pid == other.pid
            && CanonicalText.same(version, other.version) && isRunning == other.isRunning
            && CanonicalText.same(location, other.location) && windows.count == other.windows.count
            && zip(windows, other.windows).allSatisfy { $0.isExactly($1) }
    }
}

/// ListingResult is what `windows` or `apps` answered: the applications in the order shown, and how
/// many the producer left out of the answer (`apps` shows a bounded number and counts the rest).
public struct ListingResult: Sendable, Equatable {

    public enum Kind: String, Sendable, Equatable, Hashable, CaseIterable {
        case windows, apps
    }

    public let kind: Kind
    public let applications: [ListedApplication]
    public let hiddenCount: Int

    public init(kind: Kind, applications: [ListedApplication], hiddenCount: Int = 0) {
        self.kind         = kind
        self.applications = applications
        self.hiddenCount  = hiddenCount
    }

    /// Why the rows do not fit the kind, or nil: `windows` rows carry a pid and no running flag,
    /// version or location; `apps` rows carry a running flag, no pid and no windows; the hidden count
    /// is never negative.
    public var problem: String? {
        if hiddenCount < 0 { return "hidden count below zero" }
        for (position, application) in applications.enumerated() {
            if application.name.isEmpty && application.bundleID.isEmpty { return "application \(position) has no name and no bundle id" }
            switch kind {
                case .windows:
                    if application.pid == nil { return "application \(position) has no pid" }
                    if application.isRunning != nil || application.version != nil || application.location != nil {
                        return "application \(position) carries apps fields"
                    }
                case .apps:
                    if application.isRunning == nil { return "application \(position) has no running flag" }
                    if application.pid != nil || !application.windows.isEmpty { return "application \(position) carries windows fields" }
            }
        }
        return nil
    }

    public func isExactly(_ other: ListingResult) -> Bool {
        kind == other.kind && hiddenCount == other.hiddenCount && applications.count == other.applications.count
            && zip(applications, other.applications).allSatisfy { $0.isExactly($1) }
    }
}

/// ObservationResult is what `open_session` or `observe` answered: the session the scene belongs
/// to, the session's revision the scene was taken at, the calendar instant the answer carried, and
/// the real sample the scene was captured as (`current`, the primary), which is the call's own event
/// for `observe` and the session's own observation event for `open_session`. The scene text the
/// model read is a rendering of that sample.
public struct ObservationResult: Sendable, Equatable {

    public let sessionID: String
    public let sessionRevision: Int64
    public let observedAtMS: Int64
    public let sample: CaptureSampleKey

    public init(sessionID: String, sessionRevision: Int64, observedAtMS: Int64, sample: CaptureSampleKey) {
        self.sessionID       = sessionID
        self.sessionRevision = sessionRevision
        self.observedAtMS    = observedAtMS
        self.sample          = sample
    }

    /// Why the result cannot be one, or nil.
    public var problem: String? {
        if sessionID.isEmpty { return "empty session" }
        if sessionRevision < 0 { return "revision below zero" }
        if sample.phase != .current { return "sample is not current" }
        if sample.eventID.isEmpty { return "sample without event" }
        return nil
    }

    public func isExactly(_ other: ObservationResult) -> Bool {
        sessionID.utf8.elementsEqual(other.sessionID.utf8) && sessionRevision == other.sessionRevision
            && observedAtMS == other.observedAtMS && sample == other.sample
    }
}

extension CanonicalText {

    /// Whether two optional texts are the same bytes, NULL apart from any text.
    static func same(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
            case (nil, nil)       : true
            case (let a?, let b?) : a.utf8.elementsEqual(b.utf8)
            default               : false
        }
    }
}
