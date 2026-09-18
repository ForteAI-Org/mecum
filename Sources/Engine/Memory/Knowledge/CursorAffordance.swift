//
//  CursorAffordance.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

/// CursorAffordance is what the system cursor over an element implies about it, a near-free type
/// hint sampled while a person hovers. On an opaque application an I-beam still says "editable
/// text" and a pointing hand says "link or button". An unrecognized cursor is `unknown`, never a
/// guess that would poison a role hint.
public enum CursorAffordance: String, Sendable, Codable {

    case arrow
    case text
    case link
    case resize
    case drag
    case disabled
    case busy
    case crosshair
    case unknown
}
