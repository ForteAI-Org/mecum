//
//  BrainListView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import Memory
import PerceptionCore
import SwiftUI

/// BrainListView is one application's Brain as a grouped form: a section for
/// each window, with its groups, which open to show their controls, and then
/// the controls in no group; last, what the Brain saw a control do. Each
/// control carries the colour of its kind in the graph, and says how often it
/// was seen only when it was seen more than once.
struct BrainListView: View {

    let brain: UIBrain

    var body: some View {
        Form {
            ForEach(windows, id: \.self) { window in
                Section(window == "window" ? "Window" : window.capitalized) {
                    ForEach(groups(in: window), id: \.id) { group in
                        DisclosureGroup {
                            ForEach(members(of: group), id: \.anchorKey) { row($0) }
                        } label: {
                            LabeledContent {
                                Text("\(group.memberAnchors.count) \(group.sharedKind.rawValue)s")
                            } label: {
                                Label {
                                    Text(group.name ?? "Unnamed \(group.axis.rawValue)")
                                } icon: {
                                    dot(BrainPalette.colour(of: group.sharedKind))
                                }
                            }
                        }
                    }

                    ForEach(loose(in: window), id: \.anchorKey) { row($0) }
                }
            }

            if !brain.transitions.isEmpty {
                Section("Learned effects") {
                    ForEach(brain.transitions.indices, id: \.self) { index in
                        let transition = brain.transitions[index]
                        LabeledContent("\(label(of: transition.anchorKey)), \(transition.trigger.rawValue)") {
                            Text("\(transition.summary) · seen \(transition.evidence)×")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Rows

    private func row(_ anchor: ObjectAnchor) -> some View {
        LabeledContent {
            if anchor.seenCount > 1 { Text("Seen \(anchor.seenCount) times") }
        } label: {
            Label {
                Text(anchor.label.isEmpty ? "Unlabelled \(anchor.kind.rawValue)" : anchor.label)
                    .foregroundStyle(anchor.label.isEmpty ? .secondary : .primary)
            } icon: {
                dot(BrainPalette.colour(of: anchor.kind))
            }
        }
    }

    private func dot(_ colour: Color) -> some View {
        Circle()
            .fill(colour.gradient)
            .frame(
                width : 8,
                height: 8
            )
            .accessibilityHidden(true)
    }

    // MARK: Reading

    private func family(_ anchor: ObjectAnchor) -> String { anchor.window ?? "window" }

    private var windows: [String] {
        Array(Set(brain.objects.map(family))).sorted()
    }

    private func groups(in window: String) -> [SiblingGroup] {
        brain.groups.filter { group in
            group.memberAnchors.first.flatMap { key in brain.objects.first { $0.anchorKey == key } }.map(family) == window
        }
    }

    private func members(of group: SiblingGroup) -> [ObjectAnchor] {
        group.memberAnchors.compactMap { key in brain.objects.first { $0.anchorKey == key } }
    }

    private func loose(in window: String) -> [ObjectAnchor] {
        let grouped = Set(brain.groups.flatMap(\.memberAnchors))
        return brain.objects.filter { family($0) == window && !grouped.contains($0.anchorKey) }
    }

    private func label(of anchorKey: String) -> String {
        guard let anchor = brain.objects.first(where: { $0.anchorKey == anchorKey }), !anchor.label.isEmpty else {
            return "A control"
        }
        return anchor.label
    }
}
