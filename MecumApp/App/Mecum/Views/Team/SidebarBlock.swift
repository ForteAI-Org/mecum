//
//  SidebarBlock.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import SwiftUI

/// SidebarBlock is the rounded block a worker's row or tile sits on, the
/// sidebar's version of the inspector's grouped blocks, and the insets the
/// sidebar's title, blocks and footer share.
///
/// The list draws no selection of its own (`SidebarBridge`), so a selected
/// block is the selection, in the system's colours: the accent colour while
/// the list has focus in the active window, grey otherwise, as any sidebar
/// shows it. A block reaches past the list's own row inset out to `gutter`.
struct SidebarBlock: View {

    /// From the sidebar's edge to a block's edge, where a sidebar's selection sits.
    static let gutter: CGFloat = 10

    /// From the sidebar's edge to where the list starts a row's content.
    static let listContentInset: CGFloat = 16

    /// From the sidebar's edge to the content of a block, the title and the footer.
    static let contentInset: CGFloat = 20

    /// The space between two blocks, split above and below each.
    static let spacing: CGFloat = 6

    static let cornerRadius: CGFloat = 10

    let isSelected  : Bool
    let isEmphasized: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius)
            .fill(fill)
            .padding(.horizontal, Self.gutter - Self.listContentInset)
    }

    private var fill: Color {
        guard isSelected else { return Self.rest }
        return Color(nsColor: isEmphasized ? .selectedContentBackgroundColor
                                           : .unemphasizedSelectedContentBackgroundColor)
    }

    /// A block at rest: a light lift over the sidebar's material in both
    /// appearances, clearly apart from the grey of an unfocused selection.
    private static let rest = Color(nsColor: NSColor(name: "SidebarBlockRest") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.05)
            : NSColor(white: 1, alpha: 0.75)
    })
}
