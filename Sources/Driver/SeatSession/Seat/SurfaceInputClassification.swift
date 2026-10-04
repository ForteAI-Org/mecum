//
//  SurfaceInputClassification.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/09/2026.
//

import SeatCore
import SeatInput

/// SurfaceInputClassification is what the seat has actually established about
/// the toolkit drawing the surface one Command is addressed to, and therefore
/// which measured recipe that Command may be posted with.
///
/// ## Why the role of the surface is not the answer
///
/// A surface published as a modal attached to one of the application's windows
/// used to take `AppKitPlatform` by rule. The rule is wrong in both directions
/// and the sources say so: Electron presents web content through `beginSheet`,
/// so a sheet can be the host renderer's own window, and Qt draws a file dialog
/// either with the native panel or with its own widgets. A sheet therefore
/// identifies the *relation* between two windows and never the framework behind
/// the one the events have to reach.
///
/// So the evidence is the endpoint the gesture resolved, which is a reading of
/// the window server and not a name: a window of another process drawn inside
/// the surface is the out of process panel, and the surface answering for
/// itself is a window of the application the seat already drives.
///
/// ## And the capability is per Command
///
/// The remote recipe is measured for the mouse: three panels closed on
/// 26A428 with no preparation at all, the remote Window ID in field 51, the
/// remote connection in field 52 and the remote PID posted to. The keyboard
/// does not share it, because a key goes to a key window and a first responder
/// rather than to a point: it has a recipe of its own, `RemoteKeyboardPlatform`,
/// which prepares the remote owner and its key window before the events.
///
/// A Command whose recipient was never attested is still `unknown`, and an
/// unknown classification refuses rather than defaulting to either of them.
nonisolated enum SurfaceInputClassification: Sendable, Equatable {

    /// The recipient is a window of the application the seat drives, so the
    /// family the seat already drives that application with applies.
    case drivenApplication

    /// A modal of the driven application read as one accessibility leaf.
    /// A UXP leaf needs its own key window, without application activation.
    case leafSurfaceOfDrivenApplication

    /// A UXP modal whose own complete subtree qualified its destination while
    /// AX global focus named the blocked document or was absent. Make only
    /// the attested modal key, without application activation.
    case unfocusedModalOfDrivenApplication

    /// A selected UXP document under a positively inert focus proxy requires
    /// only its attested main window to become key.
    case mainWindowUnderFocusProxyOfDrivenApplication

    /// The recipient is another process's window drawn inside the surface: the
    /// out of process panel, whose measured recipe prepares nothing.
    case remotePanelContent

    /// Nothing here establishes what draws the surface this Command is
    /// addressed to. It is a refusal and never a default.
    case unknown

    /// What the seat established about the surface of one Command, from the
    /// observation's own role and from the endpoint the gesture resolved.
    ///
    /// An ordinary target is the application's own window and needs no
    /// endpoint. A modal surface without one is a Command whose recipient was
    /// never attested, which is the unknown case.
    static func of(
        _ observation: SeatObservationReference,
        endpoint     : ResolvedInputEndpoint?,
        remoteAppKitPanelServiceQualified: Bool = false
    ) -> SurfaceInputClassification {

        // An application-modal panel can be captured directly, which gives it
        // the ordinary capture role. Its endpoint still carries the independently
        // attested modal relation, and that is the only fact this decision needs.
        guard let endpoint else { return .drivenApplication }
        switch endpoint.relation {
            // A different Window ID is not by itself a foreign backend. A
            // same-process child is governed by the application's profile; only
            // a separately attested process can use the remote recipe.
            case .remoteContent
                where endpoint.identity.process != endpoint.logicalSurface.process
                    && remoteAppKitPanelServiceQualified:
                return .remotePanelContent
            case .logicalSurface where endpoint.evidence == .leafSurface:
                return .leafSurfaceOfDrivenApplication
            case .logicalSurface where endpoint.evidence == .unfocusedModalSurface:
                return .unfocusedModalOfDrivenApplication
            case .logicalSurface where endpoint.evidence == .mainWindowUnderFocusProxy:
                return .mainWindowUnderFocusProxyOfDrivenApplication
            case .logicalSurface,
                 .remoteContent where endpoint.identity.process == endpoint.logicalSurface.process:
                return .drivenApplication
            case .remoteContent: return .unknown
        }
    }

    /// The recipe this Command may be posted with, `nil` when this
    /// classification qualifies none and the Command has to be refused.
    ///
    /// `family` is what the seat drives the application with, which is the
    /// answer for its own windows and is deliberately not the answer for
    /// another process's: adding the host's Chromium preparation to a native
    /// panel because the host happens to be Electron is the substitution the
    /// measured recipe replaces.
    func platform(
        for command        : InputCommand,
        ofDrivenApplication family: (any InputPlatform)?,
        host               : WindowReference? = nil,
        recipient          : WindowReference? = nil,
        isModalSurface     : Bool = false
    ) -> (any InputPlatform)? {

        switch self {
            case .drivenApplication:
                if isModalSurface, let uxp = family as? UXPPlatform {
                    return uxp.withoutDocumentPreparation
                }
                return family

            case .leafSurfaceOfDrivenApplication:
                guard let uxp = family as? UXPPlatform else { return family }
                guard let recipient else { return nil }
                return uxp.primingKeys(in: recipient)

            case .unfocusedModalOfDrivenApplication, .mainWindowUnderFocusProxyOfDrivenApplication:
                guard let recipient else { return nil }
                return (family as? UXPPlatform)?.primingKeys(in: recipient)

            case .remotePanelContent:
                // `AppKitPlatform` prepares nothing for every Command in the
                // vocabulary, which is the `.none` the three closures used.
                return command.hasMouseLocation
                    ? AppKitPlatform()
                    : RemoteKeyboardPlatform(host: host)

            case .unknown:
                return nil
        }
    }
}
