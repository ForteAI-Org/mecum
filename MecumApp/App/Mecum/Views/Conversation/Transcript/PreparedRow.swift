//
//  PreparedRow.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// PreparedRow is a row ready to draw: its item, its laid out text and where
/// every part goes at one width and style.
///
/// It is built off the main thread by `RowPreparation` and read on the main
/// actor by a cell.
nonisolated struct PreparedRow: Sendable {
    let item    : TranscriptItem
    let text    : PreparedText
    let geometry: RowGeometry
}
