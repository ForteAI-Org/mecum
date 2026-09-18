//
//  SceneSection.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

/// SceneSection is a named panel of a window ("sidebar (TRACKS)", "top bar", "region 3") with its
/// normalized bounds. Sections sit outside the scene token on purpose: naming a panel must never
/// perturb an action guard.
public struct SceneSection: Sendable, Equatable, Hashable {

    public var name: String
    public var bounds: NormalizedRect
    /// Vertical scrollability when there is a basis to claim it, as a short note for the reader.
    /// nil means nothing is known, which is the honest default.
    public var verticalScrollNote: String?
    /// Sideways scrollability, kept apart from the vertical note: every consumer of the vertical
    /// note means the vertical axis, and a strip that only slides sideways must not walk into them.
    public var horizontalScrollNote: String?

    public init(
        name                : String,
        bounds              : NormalizedRect,
        verticalScrollNote  : String? = nil,
        horizontalScrollNote: String? = nil
    ) {
        self.name                 = name
        self.bounds               = bounds
        self.verticalScrollNote   = verticalScrollNote
        self.horizontalScrollNote = horizontalScrollNote
    }
}

extension SceneSection: Codable {

    private enum CodingKeys: String, CodingKey {
        case name
        case bounds               = "pos"
        case verticalScrollNote   = "scrolls"
        case horizontalScrollNote = "scrollsX"
    }
}
