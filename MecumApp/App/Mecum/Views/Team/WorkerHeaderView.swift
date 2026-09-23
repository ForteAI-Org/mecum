//
//  WorkerHeaderView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI
import TeamShell

/// WorkerHeaderView floats the selected worker's mascot and name at the top of
/// its conversation (§3.4), the way a messaging app names the other side.
///
/// It floats over the transcript: messages scroll under it, and the transcript
/// keeps `clearance` points free above its first message so the oldest one
/// scrolls clear of it. Its surface is Liquid Glass, the composer's language;
/// Reduce Transparency gets a solid surface instead. It carries no status line.
///
/// Clicking it, or Return or Space while it has focus, calls `open`, which
/// shows the worker's details. It is focusable whether or not keyboard
/// navigation is turned on, so the keyboard always reaches it.
struct WorkerHeaderView: View {

    /// The height the transcript keeps clear at its top: the header and its margin.
    static let clearance: CGFloat = 72

    let header: ShellChrome.Header
    let open  : () -> Void

    @Environment(\.accessibilityReduceTransparency)
    private var reducesTransparency

    @Environment(\.workerHeaderUsesMaterial)
    private var usesMaterial

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        surface(
            VStack(spacing: 2) {
                MascotView(appearance: header.appearance, size: 30)
                Text(header.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Its own width up to 200 points, not the width the conversation offers.
            .frame(maxWidth: 200)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        )
        .contentShape(shape)
        .help(header.name)
        .focusable()
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
        .padding(.top, 8)
    }

    @ViewBuilder
    private func surface(_ content: some View) -> some View {
        if reducesTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(.separator))
        } else if #available(macOS 26, *), !usesMaterial {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            // Before macOS 26 only, which this deployment target never runs; snapshots
            // force it through `workerHeaderUsesMaterial` because glass draws blank offscreen.
            content
                .background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
    }
}

extension EnvironmentValues {

    /// Draws the header on an Apple material instead of glass, for offscreen snapshots.
    @Entry var workerHeaderUsesMaterial = false
}
