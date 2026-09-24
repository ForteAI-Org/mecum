//
//  DisclosureChevron.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import SwiftUI

/// DisclosureChevron is the chevron at the trailing edge of a row that opens
/// in place, pointing down while the row is open; the turn animates with the
/// change that opens it.
struct DisclosureChevron: View {

    let isOpen: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isOpen ? 90 : 0))
            .accessibilityHidden(true)
    }
}
