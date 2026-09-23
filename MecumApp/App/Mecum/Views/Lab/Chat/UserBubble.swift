//
//  UserBubble.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SeatBroker
import SwiftUI

struct UserBubble: View {

    let text: String

    var body: some View {
        Text(text)
            .textSelection(.enabled)
            .foregroundStyle(.white)
            .padding(
                .horizontal,
                14
            )
            .padding(
                .vertical,
                10
            )
            .background(
                .tint,
                in: RoundedRectangle(
                    cornerRadius: 18,
                    style       : .continuous
                )
            )
            .frame(
                maxWidth : 520,
                alignment: .trailing
            )
    }
}
