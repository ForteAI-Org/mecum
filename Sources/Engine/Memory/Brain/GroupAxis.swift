//
//  GroupAxis.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

/// GroupAxis is the alignment of a sibling group: members share a left edge in a column, a top
/// edge in a row.
public enum GroupAxis: String, Sendable, Codable, CaseIterable {

    case column
    case row
}
