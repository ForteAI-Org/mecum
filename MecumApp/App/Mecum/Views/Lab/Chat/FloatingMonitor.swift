//
//  FloatingMonitor.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SeatBroker
import SwiftUI

/// The virtual screen as a picture-in-picture monitor. Two sizes and two
/// sources, both toggled by its header: the adopted window live, or the whole
/// Virtual Display it sits on.
///
/// The source is held here rather than read from the session on every pass
/// because the session is not observable; the session's answer is what is
/// stored, so a display that does not exist yet leaves the toggle off.
struct FloatingMonitor: View {

    let session  : AgentSession
    let isRunning: Bool

    @State
    private var expanded     = false
    @State
    private var showsDisplay = false

    var body: some View {
        // The frame is empty until a window is adopted, and a zero ratio
        // collapses the preview, so an empty seat keeps the monitor's shape.
        let frame = session.windowFrame
        let ratio = frame.height > 0 && frame.width > 0 ? frame.width / frame.height : 16.0 / 10.0

        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isRunning ? .red : .green)
                    .frame(
                        width : 7,
                        height: 7
                    )
                Text(isRunning ? "Agent acting" : "Live monitor")
                    .font(.caption.weight(.medium))
                Text("·")
                    .foregroundStyle(.tertiary)
                // The source, not the application: "Live monitor · Finder" is
                // a lie when the picture is the whole display.
                Text(showsDisplay ? "Virtual Display" : (session.app?.name ?? "nothing on the seat"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    showsDisplay = session.setPreviewShowsDisplay(!showsDisplay)
                } label: {
                    Image(systemName: showsDisplay ? "display" : "macwindow")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(showsDisplay ? "Show the adopted window" : "Show the whole Virtual Display")
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(
                .horizontal,
                10
            )
            .padding(
                .vertical,
                7
            )

            LivePreview(session: session)
                .aspectRatio(
                    ratio,
                    contentMode: .fit
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(
                    [.horizontal, .bottom],
                    6
                )
        }
        .frame(width: expanded ? 560 : 300)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: 14)
        )
        .shadow(
            color : .black.opacity(0.18),
            radius: 14,
            y     : 6
        )
    }
}
