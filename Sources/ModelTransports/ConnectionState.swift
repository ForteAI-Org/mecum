//
//  ConnectionState.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// ConnectionState is what one check of a connection found.
///
/// The cases are separate because the remedies are separate: an absent
/// credential is added here, a refused one is replaced, an unreachable
/// destination is fixed on the machine that serves it, a usage limit is waited
/// out, and a removed model is exchanged for another. One red sentence for
/// five problems names none of them, which is the failure this vocabulary
/// exists to prevent.
public enum ConnectionState: Sendable, Hashable {

    /// The destination answered, and the model that was asked about, if one
    /// was, is in its catalogue.
    case ready

    /// Nothing is stored for this connection, or the command line it goes
    /// through is not signed in.
    case credentialMissing

    /// A credential exists and the destination refused it.
    case credentialRejected(detail: String)

    /// Nothing answered at the destination.
    case unreachable(destination: String, detail: String)

    /// The destination answered that the account is over a limit.
    case usageLimited(detail: String)

    /// The destination no longer lists the model that was asked about.
    case modelRemoved(model: String)

    /// The destination answered and refused for a reason that is none of the
    /// above, in its own words.
    case refused(detail: String)

    public var isReady: Bool { self == .ready }

    /// A few words for the state line of a connection card.
    public var title: String {
        switch self {
        case .ready:              "Ready"
        case .credentialMissing:  "No credential"
        case .credentialRejected: "Credential refused"
        case .unreachable:        "Unreachable"
        case .usageLimited:       "Usage limit"
        case .modelRemoved:       "Model removed"
        case .refused:            "Refused"
        }
    }

    /// The known fact, its impact, and the next action, in that order. What
    /// the destination said is quoted last so it can be read or ignored.
    public var message: String {
        switch self {

        case .ready:
            "Ready."

        case .credentialMissing:
            "This connection has no credential yet, so nothing can be sent through it. "
                + "Add one, then check again."

        case .credentialRejected(let detail):
            "The destination refused the credential, so nothing can be sent through it. "
                + "Replace it, then check again. It said: \(detail)"

        case .unreachable(let destination, let detail):
            "Nothing answered at \(destination), so nothing can be sent through it. "
                + "Check the address, or install or start what serves it, then check again. "
                + "The attempt reported: \(detail)"

        case .usageLimited(let detail):
            "The account is over a usage limit, so nothing can be sent through it until the limit "
                + "resets. Wait, or use another connection. The destination said: \(detail)"

        case .modelRemoved(let model):
            "\(model) is no longer in this destination's catalogue, so the worker cannot run with it "
                + "and needs configuring. Choose a model to replace it."

        case .refused(let detail):
            "The destination refused the request, so nothing can be sent through it. It said: \(detail)"
        }
    }
}
