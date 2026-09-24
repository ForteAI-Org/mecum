//
//  FontExample.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import SwiftUI

/// FontExample is a worker's reply set in the conversation's font and size,
/// so General shows what a choice looks like on the text the conversation
/// really holds: a heading, a paragraph with bold, italic and inline code, a
/// list and a closing question. The code stays monospaced, as it does in the
/// conversation.
struct FontExample: View {

    /// The family chosen; empty is the system font.
    let family: String

    let size: CGFloat

    private let points = [
        "Two of them mention the launch on Friday.",
        "One asks for the budget by Monday.",
    ]

    var body: some View {
        VStack(
            alignment: .leading,
            spacing  : size * 0.6
        ) {
            Text("This week in Notes")
                .font(font(
                    scale : 1.2,
                    weight: .semibold
                ))

            Text("I opened **Notes**, read the three newest notes in *All iCloud* and saved a summary as `Summary.md`.")

            VStack(
                alignment: .leading,
                spacing  : size * 0.3
            ) {
                ForEach(points, id: \.self) { point in
                    HStack(
                        alignment: .firstTextBaseline,
                        spacing  : 8
                    ) {
                        Text("•")
                        Text(point)
                    }
                }
            }

            Text("Shall I draft a reply to each?")
        }
        .font(font(
            scale : 1,
            weight: .regular
        ))
        .frame(
            maxWidth : .infinity,
            alignment: .leading
        )
        .padding(
            .vertical,
            6
        )
        .accessibilityElement(children: .combine)
    }

    private func font(
        scale : CGFloat,
        weight: Font.Weight
    ) -> Font {
        let points = size * scale
        return family.isEmpty
            ? .system(
                size  : points,
                weight: weight
            )
            : .custom(
                family,
                size: points
            )
            .weight(weight)
    }
}
