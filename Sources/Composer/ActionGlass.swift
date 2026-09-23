//
//  ActionGlass.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// ActionGlass puts one of the composer's round buttons on interactive glass,
/// with an identity in the enclosing `GlassEffectContainer`, so the buttons
/// merge and one morphs out of the other. Off glass it leaves the button as drawn.
struct ActionGlass: ViewModifier {

    let isGlass  : Bool
    let tint     : Color?
    let id       : String
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if isGlass {
            content
                .glassEffect(.regular.tint(tint).interactive(), in: .circle)
                .glassEffectID(id, in: namespace)
        } else {
            content
        }
    }
}
