//
//  WorkerHeaderView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI
import TeamShell

/// WorkerHeaderView names the selected worker in the window's title bar
/// (§3.4): its mascot with the name below it, at the centre of the toolbar,
/// the way a messaging app names the other side. It sits in the bar with no
/// surface of its own, and the conversation scrolls under the bar. It carries
/// no status line.
///
/// Clicking it, or Return or Space while it has focus, calls `open`, which
/// shows the worker's details. It is focusable whether or not keyboard
/// navigation is turned on, so the keyboard always reaches it.
struct WorkerHeaderView: View {

    let header: ShellChrome.Header
    let open  : () -> Void

    var body: some View {
        VStack(spacing: 1) {
            MascotView(appearance: header.appearance, size: 24)
            Text(header.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        // Its own width up to 200 points, not the width the toolbar offers.
        .frame(maxWidth: 200)
        .fixedSize()
        .contentShape(Rectangle())
        .help(header.name)
        .focusable()
        // A click focuses it so Space works next, and draws no ring for it.
        .focusEffectDisabled()
        .onKeyPress(keys: [.return, .space]) { _ in
            open()
            return .handled
        }
        .onTapGesture(perform: open)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(header.name)
        .accessibilityHint(header.accessibilityHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }
}
