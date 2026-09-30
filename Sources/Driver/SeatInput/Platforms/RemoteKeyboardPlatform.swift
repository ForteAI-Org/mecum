//
//  RemoteKeyboardPlatform.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/09/2026.
//

import SeatCore

/// RemoteKeyboardPlatform is the keyboard recipe for a window of another
/// process drawn inside a modal surface, and for nothing else.
///
/// ## Why the mouse's answer is not this one
///
/// The mouse needed no preparation at all on that endpoint: three panels closed
/// on 26A428 with the remote Window ID in field 51, the remote connection in
/// field 52 and the remote PID posted to, and `AppKitPlatform` is what says so.
/// The keyboard did not follow. Changing only the recipient left Escape without
/// effect, which is the contract AppKit actually has: a key goes to the key
/// window and its first responder, and Chromium documents that `NSApp` may pick
/// a key window other than the one named on the event. So the recipient is a
/// necessary condition for a key and not a sufficient one, and the remote owner
/// has to be told which of its windows is key before the first event.
///
/// ## What it asks for, and what that is made of
///
/// `.internalAppKitState` is the Preparation the driver already owns: an
/// activation record for the owner of **this** window, followed by the
/// key-window pair, addressed to the process serial number of that window's
/// owning connection and to no other. The driver resolves the participant from
/// the reference it is handed, which for this recipe is the remote content's,
/// so the owner prepared is the remote one and the key window is the remote
/// window. Nothing here calls `_SLPSSetFrontProcessWithOptions` and nothing
/// activates an application in the person's seat.
///
/// Two live effects were measured with it on 26A428, from a debugger driving
/// the same records: `⌘⇧G` opened the Go to Folder surface, and Escape closed a
/// freshly opened panel with the remote window's destruction confirmed. Neither
/// isolates the ingredients: the key-window pair without the settle, and the
/// whole preparation without the added settle, had not opened it in the
/// attempts before, and those attempts shared one process. Whether the
/// activation record is needed on top of the pair and the wait is the part
/// still to be qualified from a clean fixture.
///
/// ## The settle is this recipe's, not a constant
///
/// 50 ms is the experimental point the two positive effects were measured at,
/// and it is stated here rather than in the shared default because that default
/// describes two other families and 30 ms is what they were measured at. The
/// driver waits it without blocking the main actor and re-checks cancellation,
/// identity, the person's intention and the gate after it, before the first
/// event.
///
/// ## The host first
///
/// On 27 that preparation alone was not enough: the service beeped at every key,
/// on every freshly opened panel, measured on DaVinci Resolve's Import Media
/// with `/`, which opens Go to Folder. What made it work, every time, was the
/// key-window pair on the panel's **host** window first, in the host's own
/// process, and 250 ms or more before the service's own Preparation; 150 ms
/// was not enough and 300 ms is the setting. The host is what tells the service
/// its view is in a key window, and it takes that long to say so. With it, `/`
/// opened Go to Folder, Escape closed it and Escape again closed the panel,
/// with the host application in the background throughout.
nonisolated public struct RemoteKeyboardPlatform: InputPlatform {

    /// The window the remote content is drawn in, nil when the caller has none.
    public let host: WindowReference?

    public init(host: WindowReference? = nil) {
        self.host = host
    }

    /// The host's key-window pair for every Command that carries keys.
    public func keyWindowPriming(for command: InputCommand) -> (host: WindowReference, settle: Duration)? {
        guard let host, preparation(for: command) == .internalAppKitState else { return nil }
        return (host, .milliseconds(300))
    }

    /// Every Command that carries keys is prepared; the mouse is not this
    /// recipe's and is answered by the measured `.none` of `AppKitPlatform`.
    public func preparation(for command: InputCommand) -> Preparation {
        switch command {
            case .key, .text, .insertText: .internalAppKitState
            case .click, .drag, .scroll  : .none
        }
    }

    /// The measured 50 ms, for every Command this recipe prepares.
    public func preparationSettle(for command: InputCommand) -> Duration {
        .milliseconds(50)
    }
}
