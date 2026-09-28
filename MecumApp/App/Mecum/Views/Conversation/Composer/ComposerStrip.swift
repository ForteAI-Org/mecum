//
//  ComposerStrip.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/09/2026.
//

import AppKit
import SwiftUI

/// ComposerStrip is a line that comes out of the top of the composer's pill
/// and says what the next message goes out with, such as the message it
/// replies to: a small symbol, a title when there is one, one line of text cut
/// with an ellipsis, and controls at its trailing end, which the caller brings.
///
/// It is joined to the pill rather than a second bar: `ComposerBar` puts it on
/// the pill's own surface, so the two share one width, outline, material and
/// shadow, and the strip only lays a darker fill over its part, so it reads as
/// a thing of its own that belongs to the composer. A click on its text runs
/// `open`. Strips stack, and only the top one rounds its top corners, into the
/// pill's; its × is a `ComposerStripCancelButton`.
struct ComposerStrip<Trailing: View>: View {

    /// The strip's height with one line, which a control in its trailing area should fit.
    static var controlHeight: CGFloat { 22 }

    private let symbol           : String
    private let tint             : Color
    private let title            : String?
    private let text             : String
    private let accessibilityText: String
    private let roundsTop        : Bool
    private let open             : () -> Void
    private let trailing         : Trailing

    /// - Parameters:
    ///   - symbol: a system symbol, drawn small at the leading end in `tint`.
    ///   - title: drawn before the text in a heavier weight; nil draws none.
    ///   - accessibilityText: what VoiceOver reads for the title and text together.
    ///   - roundsTop: whether the strip is the top of the composer, so its top
    ///     corners round into the pill's; a strip under another is square.
    ///   - open: what a click on the text does.
    ///   - trailing: the strip's controls, at its trailing end.
    init(
        symbol           : String,
        tint             : Color = .secondary,
        title            : String?,
        text             : String,
        accessibilityText: String,
        roundsTop        : Bool = true,
        open             : @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.symbol            = symbol
        self.tint              = tint
        self.title             = title
        self.text              = text
        self.accessibilityText = accessibilityText
        self.roundsTop         = roundsTop
        self.open              = open
        self.trailing          = trailing()
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(
                    size  : 11,
                    weight: .semibold
                ))
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            Button(action: open) {
                HStack(spacing: 5) {
                    if let title {
                        Text(title)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                            .layoutPriority(1)
                    }
                    Text(text)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    maxWidth : .infinity,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityText)

            trailing
        }
        .font(.system(size: 12))
        .frame(minHeight: Self.controlHeight)
        .padding(.leading, 14)
        .padding(.trailing, ComposerBar.padding)
        .padding(.vertical, 3)
        .background(
            Self.fill,
            in: UnevenRoundedRectangle(
                topLeadingRadius : roundsTop ? ComposerBar.cornerRadius : 0,
                topTrailingRadius: roundsTop ? ComposerBar.cornerRadius : 0,
                style            : .continuous
            )
        )
    }

    /// Black laid thinly over the pill's surface, a little thicker in dark,
    /// where the same veil would not show: darker than the pill in either theme.
    private static var fill: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return .black.withAlphaComponent(isDark ? 0.22 : 0.06)
        })
    }
}
