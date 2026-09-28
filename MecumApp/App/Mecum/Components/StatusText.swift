//
//  StatusText.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// StatusText is a state in words with a small dot before it, the inspector's
/// one use of colour: the key colour for work under way, green for a ready
/// connection, orange for waiting, red for trouble, grey for rest. The words
/// always say the state, so the dot only repeats it.
struct StatusText: View {

    enum Tone {
        case active
        case ready
        case waiting
        case trouble
        case quiet
    }

    private let text: String
    private let tone: Tone

    init(
        _ text: String,
        tone  : Tone
    ) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(fill)
                .frame(
                    width : 7,
                    height: 7
                )
                .accessibilityHidden(true)

            Text(text)
                .foregroundStyle(tone == .trouble ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .fixedSize(
                    horizontal: false,
                    vertical  : true
                )
        }
    }

    private var fill: AnyShapeStyle {
        switch tone {
        case .active : AnyShapeStyle(.tint)
        case .ready  : AnyShapeStyle(.green)
        case .waiting: AnyShapeStyle(.orange)
        case .trouble: AnyShapeStyle(.red)
        case .quiet  : AnyShapeStyle(.tertiary)
        }
    }
}
