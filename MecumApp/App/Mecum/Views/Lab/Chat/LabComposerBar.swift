//
//  LabComposerBar.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SeatBroker
import SwiftUI

/// Text field on top; under it, on the right, one capsule that names the
/// model and its effort and opens the model popover, then the send or stop
/// button. The capsule warms from grey to orange as the effort rises.
struct LabComposerBar: View {

    @Bindable
    var model: AppModel

    @State
    private var showsModelPopover = false

    @FocusState
    private var isFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            // Three places state the slash vocabulary and have to agree: this
            // placeholder, the help line in `AppModel.send`, and the parser.
            TextField(
                "Say what you want done, or type /observe, /click N [count]…",
                text: $model.draft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...8)
            .focused($isFocused)
            .onSubmit { Task { await model.send() } }
            // Focus as soon as the chat appears, and again when a run ends,
            // so the next goal can be typed without a click.
            .task { isFocused = true }
            .onChange(of: model.isBusy) { _, busy in if !busy { isFocused = true } }

            HStack(spacing: 10) {
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                ModelCapsule(selection: model.selection) { showsModelPopover.toggle() }
                    .popover(
                        isPresented: $showsModelPopover,
                        arrowEdge  : .bottom
                    ) {
                        ModelPopover(model: model)
                    }
                if model.isBusy {
                    Button { model.cancelRun() } label: {
                        Image(systemName: "stop.fill")
                            .font(.callout.weight(.bold))
                            .frame(
                                width : 30,
                                height: 30
                            )
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .tint(.red)
                } else {
                    Button { Task { await model.send() } } label: {
                        Image(systemName: "arrow.up")
                            .font(.callout.weight(.bold))
                            .frame(
                                width : 30,
                                height: 30
                            )
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || model.selection.model.isEmpty)
                    .keyboardShortcut(
                        .return,
                        modifiers: .command
                    )
                }
            }
        }
        .padding(14)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: 18)
        )
        .padding(
            [.horizontal, .bottom],
            16
        )
        .padding(
            .top,
            8
        )
    }
}
