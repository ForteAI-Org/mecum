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
        case .ready:              "Connected"
        case .credentialMissing:  "Setup Required"
        case .credentialRejected: "Access Rejected"
        case .unreachable:        "Can’t Connect"
        case .usageLimited:       "Usage Limit Reached"
        case .modelRemoved:       "Model Unavailable"
        case .refused:            "Request Rejected"
        }
    }

    /// A concise explanation and recovery action. Provider output is kept in
    /// `technicalDetail` so it does not obscure what the person can do next.
    public var message: String {
        switch self {

        case .ready:
            "Connected."

        case .credentialMissing:
            "Sign in or add an API key, then check the connection again."

        case .credentialRejected:
            "The API key or sign-in was rejected. Update your credentials, then check again."

        case .unreachable(let destination, _):
            "Mecum couldn’t reach \(destination). Check the address and make sure the service is running, then try again."

        case .usageLimited:
            "This account has reached its usage limit. Wait for it to reset or use another provider."

        case .modelRemoved(let model):
            "\(model) is no longer available from this provider. Choose another model for the worker."

        case .refused:
            "The provider rejected the request."
        }
    }

    /// The provider or transport output, when there is any. This is diagnostic
    /// material, not the primary explanation shown to the person.
    public var technicalDetail: String? {
        switch self {
        case .credentialRejected(let detail), .usageLimited(let detail), .refused(let detail):
            detail
        case .unreachable(_, let detail):
            detail
        case .ready, .credentialMissing, .modelRemoved:
            nil
        }
    }
}
