//
//  LabelOrigin.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

/// LabelOrigin is the accessibility attribute an element's label was read from. It says where the
/// name came from, nothing more: a title is what the toolkit calls the control, a description is
/// its help text, a value is its live content, a column is the header of the table cell it sits
/// in, and row content is the deepest text found inside a row. An element built from pixels has no
/// origin at all (`nil`), never a fictitious one.
///
/// A title or a description is the only origin a structural caption may come from, and even that
/// does not certify a stable caption: "Reply to Alice" is a title. The raw values are the ones the
/// living memory stores.
public enum LabelOrigin: String, Sendable, Equatable, Hashable, CaseIterable {

    case title
    case description
    case value
    case column
    case rowContent = "row_content"
}
