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
/// conversation puts the worker's model and effort there. It may also put a
/// view outside the pill, before it, which sits on the pill's bottom line:
/// the conversation's context ring. And it may join strips to the pill's top,
/// on the pill's own surface, such as the message a reply quotes; Escape in the
/// field can take it away (`onEscape(_:)`). A strip comes and goes as a bubble
/// enters (`stripTransition`, `stripAnimation`), and the pill grows with it.
/// A composer that queues (`queuesWhileAnswering(_:)`) hands the draft to
/// `send` during a turn too, while the circle stays Stop. There is no Add
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

    /// What sits outside the pill, before it, set with `leading(_:)`.
    private var leadingView: AnyView?

    /// What sits joined above the pill, on its surface, set with `strip(_:)`.
    private var stripView: AnyView?

    /// What Escape in the field does, set with `onEscape(_:)`; nil leaves it to the text view.
    private var escape: (() -> Void)?

    /// What answers the keys of a popup over the field, set with `popupKeys(_:)`.
    private var popupKeyHandler: ((ComposerTextView.PopupKey) -> Bool)?

    /// A count that puts the keyboard in the field each time it moves, set with `focusRequest(_:)`.
    private var focusRequest = 0

    /// Whether Return sends, or starts a new line with Command-Return sending; see `sendsOnReturn(_:)`.
    private var returnSends = true

    /// Whether sending during a turn hands the draft to `send` to queue; see `queuesWhileAnswering(_:)`.
    private var queues = false

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
        canAnswer && !isAnswering && hasText
    }

    /// Something to say to someone answering now, in a composer that queues it.
    var canQueue: Bool {
        queues && canAnswer && isAnswering && hasText
    }

    private var hasText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// "Message Milo", or what Milo needs before it can be messaged.
    var placeholder: String {
        canAnswer ? "Message \(recipient)" : "Choose a model before messaging \(recipient)."
    }

    private var kind: ComposerSurface.Kind {
        surface ?? .resolved(reducesTransparency: reducesTransparency)
    }

    var body: some View {
        // No spacing here: an absent leading view must leave no gap, so it brings its own.
        HStack(
            alignment: .bottom,
            spacing  : 0
        ) {
            leadingView

            // One surface under the strips and the pill, so they share an outline, a material and a shadow.
            VStack(spacing: 0) {
                stripView

                HStack(alignment: .bottom, spacing: 8) {
                    ComposerField(
                        text        : $draft,
                        placeholder : placeholder,
                        onSubmit    : canSend || canQueue ? send : nil,
                        returnSends : returnSends,
                        onEscape    : escape,
                        onPopupKey  : popupKeyHandler,
                        focusRequest: focusRequest
                    )
                    .padding(
                        .vertical,
                        2
                    )
                    accessoryView
                    actions
                }
                .padding(.leading, 14)
                .padding([.vertical, .trailing], Self.padding)
            }
            .modifier(ComposerSurface(
                shape: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous),
                kind : kind
            ))
        }
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

    /// The bar with `content` outside the pill, before it, on its bottom line. The content
    /// brings its own gap to the pill, so a leading view that is absent leaves none.
    func leading(@ViewBuilder _ content: () -> some View) -> ComposerBar {
        var bar = self
        bar.leadingView = AnyView(content())
        return bar
    }

    /// The bar with `content` joined above the pill, on the pill's surface:
    /// `ComposerStrip`s stacked with no spacing, or nothing. Each strip brings
    /// `stripTransition`, and the caller animates the change with `stripAnimation`.
    func strip(@ViewBuilder _ content: () -> some View) -> ComposerBar {
        var bar = self
        bar.stripView = AnyView(content())
        return bar
    }

    /// The bar that, while a turn runs, hands a draft to `send` on Return or
    /// Command-Return, to be queued, rather than doing nothing.
    func queuesWhileAnswering(_ queues: Bool) -> ComposerBar {
        var bar = self
        bar.queues = queues
        return bar
    }

    /// How a strip comes, as a bubble enters the transcript: it fades in while
    /// rising from 8 points below, and leaves fading while it sinks. With Reduce
    /// Motion it only fades.
    static func stripTransition(reducesMotion: Bool) -> AnyTransition {
        reducesMotion ? .opacity : .opacity.combined(with: .offset(y: 8))
    }

    /// The timing of a strip's coming and going, a bubble's ease-out, which the
    /// pill's growth follows in the same animation, so nothing jumps.
    static let stripAnimation = Animation.easeOut(duration: 0.24)

    /// The bar with `action` run by Escape in the field; nil leaves Escape to the text view.
    func onEscape(_ action: (() -> Void)?) -> ComposerBar {
        var bar = self
        bar.escape = action
        return bar
    }

    /// The bar whose field offers ↑ ↓, Tab, Return and Escape to `handler`
    /// first, which answers whether a popup over the field took the key
    /// (`ComposerTextView.onPopupKey`). The keyboard never leaves the field.
    func popupKeys(_ handler: ((ComposerTextView.PopupKey) -> Bool)?) -> ComposerBar {
        var bar = self
        bar.popupKeyHandler = handler
        return bar
    }

    /// The bar that puts the keyboard in its field each time `request` moves.
    func focusRequest(_ request: Int) -> ComposerBar {
        var bar = self
        bar.focusRequest = request
        return bar
    }

    /// The pill's height with one line of text: the circle and the padding around it.
    static var restingHeight: CGFloat { circleSide + 2 * padding }

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
                .background { queueShortcut }
        }
    }

    /// Command-Return while a draft can be queued. The circle is Stop then and
    /// answers Command-Period, so the shortcut that sends is on a button of its
    /// own, which draws nothing and takes no focus.
    @ViewBuilder
    private var queueShortcut: some View {
        if canQueue {
            Button(
                "Queue Message",
                action: send
            )
            .keyboardShortcut(
                .return,
                modifiers: .command
            )
            .buttonStyle(.plain)
            .focusable(false)
            .opacity(0)
            .accessibilityHidden(true)
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
        .help("End this worker’s computer session.")
        .accessibilityLabel("Release Computer")
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
        .help(isAnswering ? "Stop response." : "Send message.")
        .accessibilityLabel(isAnswering ? "Stop response from \(recipient)" : "Send Message")
    }
}
