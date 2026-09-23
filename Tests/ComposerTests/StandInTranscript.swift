//
//  StandInTranscript.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// StandInTranscript draws a few bubbles down to the window's bottom edge, so
/// the composer floats over content the way it does over the real transcript,
/// which lives in another target and needs a store to show anything.
struct StandInTranscript: View {

    private static let lines: [(fromPerson: Bool, text: String)] = [
        (true, "Can you check this morning's build?"),
        (false, "The capture suite failed on two rows. Both time out waiting for the window to settle."),
        (true, "Rerun them with the longer wait and tell me what changes."),
        (false, "Rerunning now. The first row passes with the longer wait; the second still fails "
            + "because the window never reaches the virtual display."),
        (true, "Show me the log for the second one."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 0)
            ForEach(Array(Self.lines.enumerated()), id: \.offset) { _, line in
                bubble(line.text, fromPerson: line.fromPerson)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func bubble(_ text: String, fromPerson: Bool) -> some View {
        HStack {
            if fromPerson { Spacer(minLength: 80) }
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(fromPerson ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    fromPerson ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            if !fromPerson { Spacer(minLength: 80) }
        }
    }
}
