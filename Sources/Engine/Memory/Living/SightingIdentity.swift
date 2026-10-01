//
//  SightingIdentity.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import PerceptionCore

/// SightingIdentity is what makes two observations the same object inside one window context.
///
/// An anchor key is the brain's durable identity for an object and is preferred. Without one, a
/// semantic identity (kind and normalized name) is admissible only when the name is unique among
/// the names the same scene showed, because two controls sharing a name in one window are two
/// places and must never merge on the name alone.
public enum SightingIdentity: Sendable, Hashable, Codable {

    /// The brain's anchor key: persistent across processes, never a scene element id.
    case anchor(String)

    /// A kind and a normalized name, built only through `semantic(kind:name:amongSceneNames:)`.
    case semantic(kind: ElementKind, normalizedName: String)

    /// The semantic identity of `name`, or nil when the name normalizes to nothing or when more
    /// than one of the scene's names normalizes to the same text.
    public static func semantic(
        kind           : ElementKind,
        name           : String,
        amongSceneNames: [String]
    ) -> SightingIdentity? {
        let normalized = LabelText.normalize(name)
        guard !normalized.isEmpty else { return nil }
        let sharing = amongSceneNames.filter { LabelText.normalize($0) == normalized }.count
        guard sharing <= 1 else { return nil }
        return .semantic(kind: kind, normalizedName: normalized)
    }

    /// A stable text form, one per identity, for ordering and for a storage key column.
    public var storageKey: String {
        switch self {
            case .anchor(let key)                   : "anchor:\(key)"
            case .semantic(let kind, let normalized): "semantic:\(kind.rawValue):\(normalized)"
        }
    }
}

/// SightingKey is a sighting's composite identity: the window context and the object identity.
/// Neither half alone identifies a sighting, so the same anchor in another window is another row.
public struct SightingKey: Sendable, Hashable, Codable {

    public let context: WindowContext
    public let identity: SightingIdentity

    public init(context: WindowContext, identity: SightingIdentity) {
        self.context  = context
        self.identity = identity
    }
}
