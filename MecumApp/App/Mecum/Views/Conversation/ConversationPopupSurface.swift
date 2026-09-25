//
//  ConversationPopupSurface.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import SwiftUI

/// ConversationPopupSurface is what a popup above the composer is drawn on:
/// the regular material in a rounded rectangle, a hairline edge and a soft
/// shadow. The model popup and the context popup share it.
struct ConversationPopupSurface: ViewModifier {

    func body(content: Content) -> some View {
        content
            .background(
                .regularMaterial,
                in: RoundedRectangle(
                    cornerRadius: 16,
                    style       : .continuous
                )
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: 16,
                    style       : .continuous
                )
                .strokeBorder(
                    Color(nsColor: .separatorColor),
                    lineWidth: 0.5
                )
            )
            .shadow(
                color : .black.opacity(0.16),
                radius: 12,
                y     : 4
            )
    }
}
