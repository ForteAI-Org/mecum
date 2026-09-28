//
//  ConversationModelPresenter.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import ModelTransports
import SwiftUI

/// ConversationModelPresenter shows `ConversationModelPopup` above the view it
/// modifies, the composer, through `ComposerPopupPresenter`: centred on the
/// model button as it was when the popup opened, and kept inside the
/// composer's width. A click in the window outside the button and the popup,
/// or Escape, closes it, and `onClose` runs then.
struct ConversationModelPresenter: ViewModifier {

    @Binding var isPresented: Bool

    /// The model button's frame in the window.
    let button: CGRect

    @Binding var selection: ModelSelection

    let catalogue: [ModelInfo]?

    let onClose: () -> Void

    func body(content: Content) -> some View {
        content.composerPopup(
            isPresented: $isPresented,
            placement  : .centred(on: button),
            width      : ConversationModelPopup.width,
            onClose    : onClose
        ) {
            ConversationModelPopup(
                selection: $selection,
                catalogue: catalogue
            )
        }
    }
}

extension View {

    /// Presents the composer's model popup above this view; see `ConversationModelPresenter`.
    func modelPopup(
        isPresented: Binding<Bool>,
        button     : CGRect,
        selection  : Binding<ModelSelection>,
        catalogue  : [ModelInfo]?,
        onClose    : @escaping () -> Void
    ) -> some View {
        modifier(
            ConversationModelPresenter(
                isPresented: isPresented,
                button     : button,
                selection  : selection,
                catalogue  : catalogue,
                onClose    : onClose
            )
        )
    }
}
