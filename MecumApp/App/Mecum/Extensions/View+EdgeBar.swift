//
//  View+EdgeBar.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import SwiftUI

extension View {

    /// Puts `content` along `edge` as a bar the scroll edge effect runs under
    /// on macOS 26, or as a plain safe area inset before it.
    @ViewBuilder
    func edgeBar(
        edge   : VerticalEdge,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(
                edge   : edge,
                spacing: spacing,
                content: content
            )
        } else {
            safeAreaInset(
                edge   : edge,
                spacing: spacing,
                content: content
            )
        }
    }
}
