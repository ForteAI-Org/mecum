//
//  WorkerHeaderView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// WorkerHeaderView names the selected worker in the window's title bar
/// (§3.4): its mascot with the name beside it, at the leading edge of the
/// conversation's side of the toolbar, the way a messaging app names the other
/// side. It sits in the bar with no surface of its own, and the conversation
/// scrolls under the bar. It carries no status line and does nothing when
/// clicked: the inspector has its own button.
struct WorkerHeaderView: View {

    let header: ShellChrome.Header

    var body: some View {
        HStack(spacing: 8) {
            MascotView(
                appearance: header.appearance,
                size      : 26
            )
            Text(header.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        // Its own width up to 200 points, not the width the toolbar offers.
        .frame(maxWidth: 200)
        .fixedSize()
        .help(header.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(header.name)
        .accessibilityAddTraits(.isHeader)
    }
}
