//
//  UsageLastMessage.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import AgentTurn
import ChatCore
import SwiftUI

/// UsageLastMessage is the "Last message" section both usage popovers show:
/// what the worker's latest turn read, how much of it came from the cache,
/// and what it wrote.
struct UsageLastMessage: View {

    let tokens: ProviderUsage.Tokens

    var body: some View {
        let wording = UsageWording()

        VStack(
            alignment: .leading,
            spacing  : 6
        ) {
            UsageSectionTitle("Last message")

            UsageRow(
                label : "In · cached · out",
                value : wording.lastTurn(tokens),
                spoken: wording.lastTurnSpoken(tokens)
            )
        }
    }
}
