//
//  WorkerHeaderView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI
import TeamShell

/// WorkerHeaderView floats the selected worker's mascot and name at the top
/// centre of its conversation (§3.4), the way a messaging app names the other side.
///
/// It rises into the toolbar's band, `topMargin` below the window's edge, and
/// hangs below it over the transcript, which keeps `clearance` points free
/// above its first message so the oldest one scrolls clear of it. The band
/// keeps presses for the titlebar, so `HeaderPressCatcher` takes them first. Its surface is Liquid Glass, the composer's language;
/// Reduce Transparency gets a solid surface instead. It carries no status line.
///
/// Clicking it, or Return or Space while it has focus, calls `open`, which
/// shows the worker's details. It is focusable whether or not keyboard
/// navigation is turned on, so the keyboard always reaches it.
struct WorkerHeaderView: View {

    /// The height the transcript keeps clear at its top: the part of the header
    /// that hangs below the toolbar, and a margin.
    // ponytail: assumes the unified toolbar's 52 points; measure the safe area if a compact toolbar ships.
    static let clearance: CGFloat = 34

    let header: ShellChrome.Header
    let open  : () -> Void

    @Environment(\.accessibilityReduceTransparency)
    private var reducesTransparency

    @Environment(\.workerHeaderUsesMaterial)
    private var usesMaterial

    @FocusState private var isFocused: Bool

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
        .focused($isFocused)
        // A press focuses it so Space works next, and draws no ring for it.
        .focusEffectDisabled()
        .onKeyPress(keys: [.return, .space]) { _ in
            open()
            return .handled
        }
        .background(HeaderPressCatcher {
            isFocused = true
            open()
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(header.name)
        .accessibilityHint(header.accessibilityHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .padding(.top, Self.topMargin)
    }

    /// The room between the window's top edge and the header.
    static let topMargin: CGFloat = 20

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
