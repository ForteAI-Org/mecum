//
//  BrainTimeline.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import SwiftUI

/// BrainTimeline is the Brain's growth, floating under its graph: Play grows
/// the graph again from its first node, and the slider shows it as it stood
/// at any moment, which it names at the end.
struct BrainTimeline: View {

    /// How far along the graph's span the timeline stands, 0 at its first node and 1 now.
    @Binding var progress : Double
    @Binding var isPlaying: Bool

    let moment: Date

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if progress >= 1 { progress = 0 }
                isPlaying.toggle()
            } label: {
                Label(
                    isPlaying ? "Pause" : "Play",
                    systemImage: isPlaying ? "pause.fill" : "play.fill"
                )
                .labelStyle(.iconOnly)
                .contentTransition(.symbolEffect(.replace))
                .frame(
                    width : 22,
                    height: 22
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(isPlaying ? "Pause" : "Play Brain History")

            Slider(value: $progress) {
                Text("Time")
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 200)

            Text(moment, format: .dateTime.day().month().hour().minute())
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(
                    width    : 96,
                    alignment: .trailing
                )
        }
        .padding(
            .horizontal,
            14
        )
        .padding(
            .vertical,
            6
        )
        .modifier(BrainGlass())
    }
}
