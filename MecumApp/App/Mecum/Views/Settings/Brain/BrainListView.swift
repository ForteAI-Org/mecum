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
/// was seen only when it was seen more than once. An open group's controls
/// stand apart from the group's own row, one under the other between dividers.
struct BrainListView: View {

    let brain: UIBrain

    /// The groups open.
    @State private var open: Set<UUID>

    /// - Parameter opens: the groups open from the start, as a snapshot draws them.
    init(
        brain: UIBrain,
        opens: Set<UUID> = []
    ) {
        self.brain = brain
        _open      = State(initialValue: opens)
    }

    var body: some View {
        Form {
            ForEach(windows, id: \.self) { window in
                Section(window == "window" ? "Window" : window.capitalized) {
                    ForEach(groups(in: window), id: \.id) { group in
                        DisclosureGroup(isExpanded: isOpen(group)) {
                            members(members(of: group))
                        } label: {
                            LabeledContent {
                                Text(count(group.memberAnchors.count, of: group.sharedKind.rawValue))
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
                Section("Learned Actions") {
                    ForEach(brain.transitions.indices, id: \.self) { index in
                        let transition = brain.transitions[index]
                        LabeledContent("\(label(of: transition.anchorKey)), \(triggerTitle(transition.trigger))") {
                            Text("\(transition.summary). \(evidence(transition.evidence))")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Rows

    /// A group's controls as one block under its row, set in under the group's name, the first
    /// apart from the row and each from the next by a divider.
    private func members(_ anchors: [ObjectAnchor]) -> some View {
        VStack(
            alignment: .leading,
            spacing  : 0
        ) {
            ForEach(Array(anchors.enumerated()), id: \.element.anchorKey) { index, anchor in
                if index > 0 { Divider() }

                row(anchor)
                    .padding(
                        .vertical,
                        6
                    )
            }
        }
        .padding(
            .top,
            10
        )
        .padding(
            .leading,
            24
        )
    }

    private func isOpen(_ group: SiblingGroup) -> Binding<Bool> {
        Binding(
            get: { open.contains(group.id) },
            set: { isOpen in
                if isOpen { open.insert(group.id) } else { open.remove(group.id) }
            }
        )
    }

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

    private func count(_ value: Int, of noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    private func evidence(_ value: Int) -> String {
        value == 1 ? "Seen once" : "Seen \(value) times"
    }

    private func triggerTitle(_ trigger: TransitionTrigger) -> String {
        switch trigger {
        case .hover:      "Hover"
        case .click:      "Click"
        case .rightClick: "Right-click"
        }
    }
}
