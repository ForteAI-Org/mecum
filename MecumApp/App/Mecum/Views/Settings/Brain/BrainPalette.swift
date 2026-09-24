//
//  BrainPalette.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import PerceptionCore
import SwiftUI

/// BrainPalette is the colour each kind of node is drawn in, the same in the
/// graph and in the list: a window in the accent colour, and a group in the
/// colour of the controls it holds, so each group reads as one constellation.
enum BrainPalette {

    static func colour(of kind: BrainGraph.Kind) -> Color {
        switch kind {
        case .window                                   : .accentColor
        case .group(let element), .control(let element): colour(of: element)
        }
    }

    static func colour(of kind: ElementKind) -> Color {
        switch kind {
        case .control         : .blue
        case .icon            : .purple
        case .text            : .gray
        case .image           : .teal
        case .overlayCandidate: .pink
        }
    }
}
