//
//  ComposerBar.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// ComposerBar is the conversation's composer (§13.1): a pill that floats over
/// the bottom of the transcript, holding the field and one circle pinned to its
/// bottom-trailing corner, Send, or Stop while a turn runs. While the recipient
/// holds the computer, a quiet Release the computer button comes out of the
/// circle toward the leading side; the circle itself never moves.
///
/// The bar is inset from the edges it is placed against and grows upward with
/// its text. The caller lays it over the transcript and gives the transcript
/// the bar's height as its bottom inset, so the last message scrolls clear of it.
///
/// It carries no model, effort, tokens or provider, and no Add context or
/// microphone: nothing supplies attachments or voice yet, and a control that
/// does nothing is not shown (§21.2). A recipient that cannot answer says so
/// only in the placeholder, with Send disabled; the draft stays editable, as
/// it does during a turn, where only sending waits for the turn to end.
public struct ComposerBar: View {

    /// The circle's side, and the pill's height at one line with `padding` around it.
    static let circleSide: CGFloat = 28

    static let padding: CGFloat = 5

    /// The pill is a capsule at one line and keeps these ends as it grows.
    static let cornerRadius = circleSide / 2 + padding

    /// The release button's symbol: a door with an arrow out of it, leaving the seat.
    static let releaseSymbol = "rectangle.portrait.and.arrow.right"

    @Binding private var draft: String

    private let recipient  : String
    private let canAnswer  : Bool
    private let isAnswering: Bool
    private let send       : () -> Void
    private let stop       : () -> Void
    private let release    : (() -> Void)?

    /// The surface a snapshot draws instead of the platform's.
    var surface: ComposerSurface.Kind?

    @Environment(\.accessibilityReduceTransparency)
    private var reducesTransparency

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    /// - Parameters:
    ///   - recipient: the worker's name, in the placeholder and the labels.
    ///   - canAnswer: the recipient has a model that can answer; without one Send is disabled.
    ///   - isAnswering: a turn runs for the recipient, so the circle is Stop.
    ///   - release: gives the computer back; nil while the recipient does not hold it,
    ///     and the button is shown only while it is not nil.
    public init(
        draft      : Binding<String>,
        recipient  : String,
        canAnswer  : Bool,
        isAnswering: Bool,
        send       : @escaping () -> Void,
        stop       : @escaping () -> Void,
        release    : (() -> Void)? = nil
    ) {
        _draft           = draft
        self.recipient   = recipient
        self.canAnswer   = canAnswer
        self.isAnswering = isAnswering
        self.send        = send
        self.stop        = stop
        self.release     = release
    }

    /// Something to say, someone to answer it, and no turn running for them.
    var canSend: Bool {
        canAnswer && !isAnswering && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// "Message Milo", or what Milo needs before it can be messaged.
    var placeholder: String {
        canAnswer ? "Message \(recipient)" : "Choose a model to message \(recipient)"
    }

    private var kind: ComposerSurface.Kind {
        surface ?? .resolved(reducesTransparency: reducesTransparency)
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ComposerField(text: $draft, placeholder: placeholder, onSubmit: canSend ? send : nil)
                .padding(.vertical, 2)
            actions
        }
        .padding(.leading, 14)
        .padding([.vertical, .trailing], Self.padding)
        .modifier(ComposerSurface(
            shape: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous),
            kind : kind
        ))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// Release, when shown, beside the circle: it comes out of the circle to the left and goes back into it.
    private var actions: some View {
        HStack(spacing: 6) {
            if let release {
                releaseButton(release)
                    .transition(.scale(scale: 0.3, anchor: .trailing).combined(with: .opacity))
            }
            circle
        }
        .animation(reducesMotion ? nil : .spring(duration: 0.35, bounce: 0.15), value: release != nil)
    }

    private func releaseButton(_ release: @escaping () -> Void) -> some View {
        Button(action: release) {
            Image(systemName: Self.releaseSymbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: Self.circleSide, height: Self.circleSide)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Release the computer")
        .accessibilityLabel("Release the computer")
    }

    /// Send, which becomes Stop in the same place while a turn runs.
    private var circle: some View {
        let isEnabled = isAnswering || canSend
        let fill      = isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)
        return Button(action: isAnswering ? stop : send) {
            Image(systemName: isAnswering ? "stop.fill" : "arrow.up")
                .font(.system(size: isAnswering ? 11 : 13, weight: .bold))
                .foregroundStyle(isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                .frame(width: Self.circleSide, height: Self.circleSide)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .keyboardShortcut(isAnswering ? KeyboardShortcut(".", modifiers: .command)
                                      : KeyboardShortcut(.return, modifiers: .command))
        .help(isAnswering ? "Stop the answer (Command Period)" : "Send (Return)")
        .accessibilityLabel(isAnswering ? "Stop \(recipient)'s answer" : "Send")
    }
}
