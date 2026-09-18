//
//  ElementKind.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

/// ElementKind is what a scene element is to the reader: a run of text, a bare icon, a control
/// (an icon fused with the text that names it, or a switch carrying state), a photographic surface
/// kept as one targetable box, or an overlay glyph inside such a surface whose nature is uncertain.
///
/// The raw values are the strings the scene JSON has always carried.
public enum ElementKind: String, Sendable, Codable, CaseIterable {

    case text
    case icon
    case control
    case image
    case overlayCandidate = "overlay-candidate"
}
