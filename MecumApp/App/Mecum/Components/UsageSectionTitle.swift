//
//  UsageSectionTitle.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import SwiftUI

/// UsageSectionTitle heads one section of a usage popover, the token
/// counter's or the context ring's, and is a heading to VoiceOver.
struct UsageSectionTitle: View {

    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
    }
}
