//
//  RoundGlass.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// RoundGlass puts one of the composer's round buttons on interactive Liquid
/// Glass, tinted when it is given a tint, with an identity in the enclosing
/// `GlassEffectContainer` so the buttons merge and one comes out of the other.
/// Off glass, and before macOS 26, it leaves the button as drawn. The bar under
/// them is never glass.
struct RoundGlass: ViewModifier {

    let isGlass  : Bool
    let tint     : Color?
    let id       : String
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if isGlass, #available(macOS 26, *) {
            content
                .glassEffect(.regular.tint(tint).interactive(), in: .circle)
                .glassEffectID(id, in: namespace)
        } else {
            content
        }
    }
}
