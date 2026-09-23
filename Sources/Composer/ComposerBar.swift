//
//  ComposerBar.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// ComposerBar is the conversation's composer (§13.1): the field, Send, Stop
/// while a turn runs, and why the recipient cannot answer when that is known.
///
/// It carries no model, effort, tokens or provider, and no Add context or
/// microphone: nothing supplies attachments or voice yet, and a control that
/// does nothing is not shown (§21.2). The draft is the caller's binding and
/// stays editable during a turn; only sending waits for the turn to end.
public struct ComposerBar: View {

    @Binding private var draft: String

    private let recipient  : String
    private let notice     : String?
    private let isAnswering: Bool
    private let send       : () -> Void
    private let stop       : () -> Void
    private let chooseModel: () -> Void

    /// - Parameters:
    ///   - recipient: the worker's name, in the placeholder and the labels.
    ///   - notice: why the recipient cannot answer, or nil when it can.
    ///   - isAnswering: a turn runs for the recipient, so Send waits and Stop shows.
    public init(
        draft      : Binding<String>,
        recipient  : String,
        notice     : String?,
        isAnswering: Bool,
        send       : @escaping () -> Void,
        stop       : @escaping () -> Void,
        chooseModel: @escaping () -> Void
    ) {
        _draft           = draft
        self.recipient   = recipient
        self.notice      = notice
        self.isAnswering = isAnswering
        self.send        = send
        self.stop        = stop
        self.chooseModel = chooseModel
    }

    /// Something to say and no turn running for the recipient.
    var canSend: Bool {
        !isAnswering && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            if let notice {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(notice, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Choose a model", action: chooseModel)
                        .controlSize(.small)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                ComposerField(text: $draft, placeholder: "Message \(recipient)", onSubmit: canSend ? send : nil)

                if isAnswering {
                    Button("Stop", systemImage: "stop.circle.fill", action: stop)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .keyboardShortcut(".", modifiers: .command)
                        .help("Stop the answer (Command Period)")
                        .accessibilityLabel("Stop \(recipient)'s answer")
                }

                Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
                    .help("Send (Return)")
            }
        }
        .padding(12)
    }
}
