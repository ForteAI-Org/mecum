//
//  RunRecord+OutcomeStyle.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SeatBroker
import AppKit
import SwiftUI

extension RunRecord.Outcome {

    var icon: String {
        switch self {
            case .completed: "checkmark.seal.fill"
            case .blocked  : "hand.raised.fill"
            case .failed   : "xmark.octagon.fill"
            case .cancelled: "stop.circle.fill"
        }
    }

    var color: Color {
        switch self {
            case .completed: .green
            case .blocked  : .orange
            case .failed   : .red
            case .cancelled: .gray
        }
    }

    var title: String { rawValue.capitalized }
}
