//
//  UsagePopover.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import SwiftUI

/// UsagePopover is the layout both usage popovers share, the token counter's
/// and the context ring's: their sections one under the other at a fixed
/// width, in the callout size, which the caller parts with `Divider`s.
struct UsagePopover<Content: View>: View {

    @ViewBuilder
    let content: () -> Content

    var body: some View {
        VStack(
            alignment: .leading,
            spacing  : 12
        ) {
            content()
        }
        .font(.callout)
        .padding(16)
        .frame(
            width    : 280,
            alignment: .leading
        )
    }
}
