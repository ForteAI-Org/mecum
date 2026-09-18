//
//  SceneIdentity.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

/// SceneIdentity derives an element's stable id, the key a model echoes and memory files under.
///
/// A labeled element is `kind|normalized label`: digit-sensitive, so "Audio 6" and "Audio 7" stay
/// apart, and position-free, so a resize or a scroll does not rename it. Two elements with the same
/// key on one screen are a real collision the resolver settles with sections and rows, never a bug
/// in the key. An unlabeled element has nothing but its place, so it takes a coarse tenth-of-window
/// cell, `?|@x,y`, which is stable across pixel jitter.
public enum SceneIdentity {

    public static func key(kind: ElementKind, label: String, bounds: NormalizedRect, isUnlabeled: Bool) -> String {
        let normalized = LabelText.normalize(label)
        guard !isUnlabeled, !normalized.isEmpty else {
            return "?|@\(Int((bounds.x * 10).rounded())),\(Int((bounds.y * 10).rounded()))"
        }
        return "\(kind.rawValue)|\(normalized)"
    }
}
