//
//  MascotView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Mascots
import SwiftUI
import Workspace

/// MascotView shows a worker's mascot at a fixed size.
///
/// It is hidden from assistive technology: the mascot is the same identity the
/// row's name and label already carry, and reading a picture of a ball adds
/// nothing. It carries no selection or state tint either, so selecting a
/// worker never repaints its own colour.
struct MascotView: View {

    let appearance: WorkerAppearance
    var size      : CGFloat = 32

    var body: some View {
        Image(nsImage: MascotImages.image(for: appearance, size: size))
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
