//
//  MessageRow.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SeatBroker
import SwiftUI

struct MessageRow: View {

    let message: ChatMessage

    var body: some View {
        HStack(
            alignment: .bottom,
            spacing  : 0
        ) {
            if message.role == .user {
                Spacer(minLength: 120)
                UserBubble(text: message.text)
            } else {
                SystemBubble(message: message)
                Spacer(minLength: 60)
            }
        }
    }
}
