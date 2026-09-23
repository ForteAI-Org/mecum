//
//  TeamSidebarFooter.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SwiftUI

/// The team's model connections, pinned at the foot of the sidebar so the
/// team scrolls and it stays, with the ready ones counted at the trailing
/// edge. The Team menu holds the same command.
struct TeamSidebarFooter: View {

    let team     : TeamModel
    let isCompact: Bool

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    var body: some View {
        Button {
            team.isShowingConnections = true
        } label: {
            // One layout, as a worker's row. Compact, the badge sits under the symbol, where a tile
            // has its name.
            let layout = isCompact ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(isCompact ? .title3 : .body)

                if !isCompact {
                    Text("Connections")
                        .fixedSize()
                        // Leaving at once: a fading copy was drawn at the top of the sidebar during a resize.
                        .transition(reducesMotion ? .identity : .asymmetric(
                            insertion: .opacity.animation(.easeIn(duration: 0.15).delay(0.15)),
                            removal  : .identity
                        ))
                    Spacer(minLength: 4)
                }

                readyBadge
            }
            // As on a row: the badge's number moves with its capsule instead of fading apart from it.
            .contentTransition(.identity)
            .frame(
                maxWidth : .infinity,
                alignment: isCompact ? .center : .leading
            )
            .contentShape(Rectangle())
        }
        // Plain, so SwiftUI draws the label and moves its parts; a borderless one cross-faded it whole.
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(
            .horizontal,
            isCompact ? 0 : SidebarBlock.contentInset
        )
        .padding(
            .vertical,
            10
        )
        .help("The model connections the team uses")
        .accessibilityLabel("Connections")
        .accessibilityValue(readyDescription)
    }

    /// How many providers the last checks found ready. A provider not checked
    /// yet is not counted, since nothing is checked before the connections or
    /// a worker's profile are opened.
    private var readyConnections: Int {
        ModelProvider.allCases.count { team.connections.states[$0]?.isReady == true }
    }

    /// A green dot and the count of ready connections, in a quiet capsule; nothing while none is ready.
    @ViewBuilder
    private var readyBadge: some View {
        if readyConnections > 0 {
            HStack(spacing: 4) {
                Circle()
                    .fill(.green)
                    .frame(
                        width : 6,
                        height: 6
                    )

                Text("\(readyConnections)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .padding(
                .horizontal,
                6
            )
            .frame(minHeight: 18)
            .background(Capsule().fill(.quaternary))
            .accessibilityHidden(true)
        }
    }

    private var readyDescription: String {
        switch readyConnections {
        case 0:  ""
        case 1:  "1 connection ready"
        default: "\(readyConnections) connections ready"
        }
    }
}
