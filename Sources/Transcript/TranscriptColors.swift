//
//  TranscriptColors.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit

/// TranscriptColors holds the transcript's two neutral surfaces, each with a
/// light and a dark value. The person's bubble takes the accent colour and a
/// mascot keeps its own; neither is defined here.
enum TranscriptColors {

    static let neutralSurface = NSColor(name: "TranscriptNeutralSurface") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.22, alpha: 1)
            : NSColor(white: 0.93, alpha: 1)
    }

    static let cardSurface = NSColor(name: "TranscriptCardSurface") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.16, alpha: 1)
            : NSColor(white: 0.97, alpha: 1)
    }
}
