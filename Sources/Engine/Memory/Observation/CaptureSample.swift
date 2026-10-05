//
//  CaptureSample.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import EngineCore
import Foundation
import PerceptionCore

/// CaptureElement is one structural element a sample saw, as the living memory keeps it: the
/// element's kind and role, its label with the attribute it came from, the structural path it sits
/// at, whether it sits inside a collection, the state it showed and where it was. Only an element
/// with a role is a capture element: a pixel-only element has no structural fact to keep, and the
/// scene it came from is not what this row stores.
///
/// `containerPath` is the path a structural signature reads: for an element inside a collection it
/// is the path up to the collection, never the row's name, which is content; outside a collection
/// it is the element's container path. The root is the empty path.
///
/// Equality and hashing read every text as its UTF-8 bytes, as the file keeps them: two elements
/// whose role, label or path are canonically equivalent but different bytes are two elements. A
/// bound is the number it is, so `-0.0` and `0.0` are one bound.
public struct CaptureElement: Sendable, Equatable, Hashable {

    public var kind: ElementKind
    public var role: String
    public var label: String
    public var labelOrigin: LabelOrigin?
    public var containerPath: String
    public var isUnderCollection: Bool
    public var state: ControlState?
    public var bounds: NormalizedRect

    public init(
        kind             : ElementKind,
        role             : String,
        label            : String,
        labelOrigin      : LabelOrigin?,
        containerPath    : String,
        isUnderCollection: Bool,
        state            : ControlState?,
        bounds           : NormalizedRect
    ) {
        self.kind              = kind
        self.role              = role
        self.label             = label
        self.labelOrigin       = labelOrigin
        self.containerPath     = containerPath
        self.isUnderCollection = isUnderCollection
        self.state             = state
        self.bounds            = bounds
    }

    public static func == (lhs: CaptureElement, rhs: CaptureElement) -> Bool {
        lhs.kind == rhs.kind && lhs.role.utf8.elementsEqual(rhs.role.utf8) && lhs.label.utf8.elementsEqual(rhs.label.utf8)
            && lhs.labelOrigin == rhs.labelOrigin && lhs.containerPath.utf8.elementsEqual(rhs.containerPath.utf8)
            && lhs.isUnderCollection == rhs.isUnderCollection && lhs.state == rhs.state && lhs.bounds == rhs.bounds
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        for text in [role, label, containerPath] {
            hasher.combine(text.utf8.count)
            for byte in text.utf8 { hasher.combine(byte) }
        }
        hasher.combine(labelOrigin)
        hasher.combine(isUnderCollection)
        hasher.combine(state)
        hasher.combine(bounds)
    }

    /// The capture element of a scene element, or nil for an element with no role.
    public init?(_ element: SceneElement) {
        guard let role = element.role else { return nil }
        self.init(
            kind             : element.kind,
            role             : role,
            label            : element.label,
            labelOrigin      : element.labelOrigin,
            containerPath    : element.collectionPath ?? element.container ?? "",
            isUnderCollection: element.collectionPath != nil,
            state            : element.state,
            bounds           : element.bounds
        )
    }
}

/// CaptureSample is one sample of the living memory: the identity (event, phase, ordinal), the
/// window's title as a hint, the producer's session revision when it had one, the surface the
/// capture was taken of, the quality of its accessibility read, and the structural elements it
/// saw. It is what a producer offers and what a reader gets back, column for column, with no
/// serialized dump in between.
///
/// Equality is the typed, exact comparison of every persisted fact: every text (the window's title,
/// each element's role, label and path, the quality's window role and subrole) byte for byte, NULL
/// apart from empty text, the elements in order, every bound as the number it is; it is what
/// decides whether two offers under one key are the same sample. `CaptureQuality`'s own equality,
/// Perception's, is not used for it. `fingerprint` is a digest for diagnostics and conflict reports,
/// never the decision.
public struct CaptureSample: Sendable, Equatable {

    public var key: CaptureSampleKey
    public var windowTitle: String?
    public var sessionRevision: Int64?
    public var surface: CaptureSurface
    public var quality: CaptureQuality
    public var elements: [CaptureElement]

    public init(
        key            : CaptureSampleKey,
        windowTitle    : String?,
        sessionRevision: Int64?,
        surface        : CaptureSurface,
        quality        : CaptureQuality,
        elements       : [CaptureElement]
    ) {
        self.key             = key
        self.windowTitle     = windowTitle
        self.sessionRevision = sessionRevision
        self.surface         = surface
        self.quality         = quality
        self.elements        = elements
    }

    public static func == (lhs: CaptureSample, rhs: CaptureSample) -> Bool {
        func same(_ a: String?, _ b: String?) -> Bool {
            switch (a, b) {
                case (nil, nil)       : true
                case (let a?, let b?) : a.utf8.elementsEqual(b.utf8)
                default               : false
            }
        }
        let p = lhs.quality, q = rhs.quality
        return lhs.key == rhs.key && same(lhs.windowTitle, rhs.windowTitle) && lhs.sessionRevision == rhs.sessionRevision
            && lhs.surface == rhs.surface
            && p.walkCompleted == q.walkCompleted && p.stoppedBy == q.stoppedBy && p.windowFound == q.windowFound
            && p.isGrantAvailable == q.isGrantAvailable && same(p.windowRole, q.windowRole) && same(p.windowSubrole, q.windowSubrole)
            && p.nodesVisited == q.nodesVisited && p.elementsEmitted == q.elementsEmitted
            && lhs.elements == rhs.elements
    }

    /// The sample of a perceived window: its scene's role-bearing elements, in scene order, with
    /// the quality and the surface the provider stated for this capture.
    public init(key: CaptureSampleKey, of window: PerceivedWindow, sessionRevision: Int64? = nil) {
        self.init(
            key            : key,
            windowTitle    : window.scene.windowTitle,
            sessionRevision: sessionRevision,
            surface        : window.surface,
            quality        : window.capture,
            elements       : window.scene.elements.compactMap(CaptureElement.init)
        )
    }

    /// Refuses a sample no store should be asked to write: no identity, a negative ordinal, an
    /// element without role or label, quality facts that contradict each other, or bounds that are
    /// not finite numbers. Nothing is repaired: a refused sample is not written at all.
    public func validate() throws {
        if key.eventID.isEmpty { throw ObservationContractError.invalidRecord(.emptyEventID) }
        if key.ordinal < 0 { throw ObservationContractError.invalidRecord(.negativeOrdinal) }
        if let inconsistency = quality.inconsistency {
            throw ObservationContractError.invalidRecord(.inconsistentQuality(inconsistency))
        }
        for element in elements {
            if element.role.isEmpty { throw ObservationContractError.invalidRecord(.emptyRole) }
            if element.label.isEmpty { throw ObservationContractError.invalidRecord(.emptyLabel) }
            guard element.bounds.isFinite else { throw ObservationContractError.invalidRecord(.nonFiniteBounds) }
        }
    }

    /// The quality facts as the eight stored fields, in the registry's order.
    public var fields: [(CaptureField, CaptureFieldValue)] {
        [
            (.walkCompleted,   quality.walkCompleted.map(CaptureFieldValue.boolean) ?? .notObserved),
            (.stoppedBy,       quality.stoppedBy.map { .text($0.rawValue) } ?? .notObserved),
            (.windowFound,     quality.windowFound.map(CaptureFieldValue.boolean) ?? .notObserved),
            (.grantAvailable,  quality.isGrantAvailable.map(CaptureFieldValue.boolean) ?? .notObserved),
            (.windowRole,      quality.windowRole.map(CaptureFieldValue.text) ?? .notObserved),
            (.windowSubrole,   quality.windowSubrole.map(CaptureFieldValue.text) ?? .notObserved),
            (.nodesVisited,    quality.nodesVisited.map { .integer(Int64($0)) } ?? .notObserved),
            (.elementsEmitted, quality.elementsEmitted.map { .integer(Int64($0)) } ?? .notObserved),
        ]
    }

    /// A digest of the sample's content for diagnostics and conflict reports: every field with its
    /// length and a NULL marker, every bound as its exact bits. It never decides equality; `==` does.
    public var fingerprint: String {
        var parts: [String] = [
            CanonicalText.field(windowTitle), CanonicalText.field(sessionRevision.map(String.init)),
            surface.rawValue, quality.completeness.rawValue,
        ]
        for (field, value) in fields { parts.append("\(field.rawValue)=\(Self.render(value))") }
        for element in elements {
            parts.append([
                element.kind.rawValue, element.role, CanonicalText.field(element.label),
                CanonicalText.field(element.labelOrigin?.rawValue), CanonicalText.field(element.containerPath),
                element.isUnderCollection ? "collection" : "", CanonicalText.field(element.state?.rawValue),
                Self.render(element.bounds),
            ].joined(separator: "|"))
        }
        return StructuralDigest.fnv1a(parts.joined(separator: "\u{1E}"))
    }

    private static func render(_ value: CaptureFieldValue) -> String {
        switch value {
            case .boolean(let flag) : flag ? "1" : "0"
            case .text(let text)    : CanonicalText.field(text)
            case .integer(let count): String(count)
            case .notObserved       : "?"
        }
    }

    private static func render(_ rect: NormalizedRect) -> String {
        rect.array.map { String($0.bitPattern, radix: 16) }.joined(separator: ",")
    }
}

extension NormalizedRect {

    /// True when every bound is a finite number: what a stored geometry must be, since the file
    /// keeps NULL for NaN and an infinity for an infinity, and neither rebuilds a rectangle.
    public var isFinite: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
    }
}

extension CaptureQuality {

    /// The quality the eight stored fields add up to. Refuses a value in the wrong storage class and
    /// a stop reason outside the vocabulary; a `notObserved` field stays `nil`.
    public init(fields: [CaptureField: CaptureFieldValue]) throws {
        func boolean(_ field: CaptureField) throws -> Bool? {
            switch fields[field] {
                case .boolean(let flag)?: return flag
                case .notObserved?, nil : return nil
                default                 : throw ObservationContractError.malformedObservation(
                    observationID: 0, malformation: .valueKindMismatch(field.rawValue))
            }
        }
        func text(_ field: CaptureField) throws -> String? {
            switch fields[field] {
                case .text(let text)?  : return text
                case .notObserved?, nil: return nil
                default                : throw ObservationContractError.malformedObservation(
                    observationID: 0, malformation: .valueKindMismatch(field.rawValue))
            }
        }
        func integer(_ field: CaptureField) throws -> Int? {
            switch fields[field] {
                case .integer(let count)?: return Int(count)
                case .notObserved?, nil  : return nil
                default                  : throw ObservationContractError.malformedObservation(
                    observationID: 0, malformation: .valueKindMismatch(field.rawValue))
            }
        }
        let stopped: StopReason?
        if let code = try text(.stoppedBy) {
            guard let reason = StopReason(rawValue: code) else { throw ObservationContractError.unknownStopReason(code) }
            stopped = reason
        } else {
            stopped = nil
        }
        self.init(
            walkCompleted   : try boolean(.walkCompleted),
            stoppedBy       : stopped,
            windowFound     : try boolean(.windowFound),
            isGrantAvailable: try boolean(.grantAvailable),
            windowRole      : try text(.windowRole),
            windowSubrole   : try text(.windowSubrole),
            nodesVisited    : try integer(.nodesVisited),
            elementsEmitted : try integer(.elementsEmitted)
        )
    }
}
