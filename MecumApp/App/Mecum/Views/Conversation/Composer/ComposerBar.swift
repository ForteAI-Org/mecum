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
/// The caller may put one accessory in the row, before the buttons: the
/// conversation puts the worker's model and effort there. There is no Add
/// context or microphone: nothing supplies attachments or voice yet, and a
/// control that does nothing is not shown (§21.2). A recipient that cannot answer says so
/// only in the placeholder, with Send disabled; the draft stays editable, as
/// it does during a turn, where only sending waits for the turn to end.
struct ComposerBar: View {

    /// The circle's side, and the pill's height at one line with `padding` around it.
    static let circleSide: CGFloat = 28

    static let padding: CGFloat = 5

    /// A rounded rectangle, a little squarer than a capsule, with the same corners at every height.
    static let cornerRadius: CGFloat = 12

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

    /// Whether the round buttons are Liquid Glass; a test measuring the drawn circle turns it off,
    /// since glass composites only in the window server. Nil is the platform's: glass unless
    /// Reduce Transparency is on, and never before macOS 26, which has no glass.
    var buttonGlass: Bool?

    /// What sits in the row before the buttons, set with `accessory(_:)`.
    private var accessoryView: AnyView?

    /// Whether Return sends, or starts a new line with Command-Return sending; see `sendsOnReturn(_:)`.
    private var returnSends = true

    @Namespace
    private var glass

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
    init(
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

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ComposerField(text: $draft, placeholder: placeholder, onSubmit: canSend ? send : nil, returnSends: returnSends)
                .padding(.vertical, 2)
            accessoryView
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

    /// The bar with Return sending, or starting a new line with Command-Return sending.
    func sendsOnReturn(_ sends: Bool) -> ComposerBar {
        var bar = self
        bar.returnSends = sends
        return bar
    }

    /// The bar with `content` in its row, before the buttons.
    func accessory(@ViewBuilder _ content: () -> some View) -> ComposerBar {
        var bar = self
        bar.accessoryView = AnyView(content())
        return bar
    }

    private var isGlass: Bool {
        guard #available(macOS 26, *) else { return false }
        return buttonGlass ?? !reducesTransparency
    }

    /// Release, when shown, beside the circle: it comes out of the circle to the left and goes back
    /// into it, and on glass the two shapes merge as one control.
    private var actions: some View {
        Group {
            if #available(macOS 26, *) {
                GlassEffectContainer(spacing: 6) { buttons }
            } else {
                buttons
            }
        }
        .animation(reducesMotion ? nil : .spring(duration: 0.35, bounce: 0.15), value: release != nil)
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            if let release {
                releaseButton(release)
                    .transition(isGlass ? .identity : .scale(scale: 0.3, anchor: .trailing)
                        .combined(with: .opacity))
            }
            circle
        }
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
        .modifier(RoundGlass(isGlass: isGlass, tint: nil, id: "release", namespace: glass))
        .help("Release the computer")
        .accessibilityLabel("Release the computer")
    }

    /// Send, which becomes Stop in the same place while a turn runs. It takes the accent as soon
    /// as there is something to send, with an animated change, and with nothing to send it is
    /// plain glass with a secondary arrow rather than a dark disc.
    private var circle: some View {
        let isEnabled = isAnswering || canSend
        // On glass the tint is the glass's own; off glass the circle is filled.
        let fill = isGlass ? AnyShapeStyle(.clear)
            : isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary.opacity(0.6))
        return Button(action: isAnswering ? stop : send) {
            Image(systemName: isAnswering ? "stop.fill" : "arrow.up")
                .font(.system(size: isAnswering ? 11 : 13, weight: .bold))
                .foregroundStyle(isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: Self.circleSide, height: Self.circleSide)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(RoundGlass(isGlass: isGlass, tint: isEnabled ? .accentColor : nil, id: "circle", namespace: glass))
        .animation(reducesMotion ? nil : .easeInOut(duration: 0.2), value: isEnabled)
        .disabled(!isEnabled)
        .keyboardShortcut(isAnswering ? KeyboardShortcut(".", modifiers: .command)
                                      : KeyboardShortcut(.return, modifiers: .command))
        .help(isAnswering ? "Stop the answer (Command Period)" : returnSends ? "Send (Return)" : "Send (Command-Return)")
        .accessibilityLabel(isAnswering ? "Stop \(recipient)'s answer" : "Send")
    }
}
