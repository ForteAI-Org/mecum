//
//  ProviderConnection.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// ProviderConnection is the connection half of the three levels §7.1 keeps
/// apart: authentication and destination, which is neither the model nor an
/// agent adapter.
///
/// Whether a worker on the connection answers, and how, is `WorkerAnswer`'s
/// to say, not this value's.
///
/// The value is derived, not stored: a connection is what a provider and the
/// current settings already say it is, so there is no second copy of a host or
/// an endpoint to keep in step.
public struct ProviderConnection: Sendable, Hashable, Identifiable {

    /// How the destination is authenticated. It names what this app holds,
    /// which is what decides whether a credential can be replaced from here.
    public enum Authentication: String, Sendable, Hashable {

        /// A subscription reached through a command line the person signed
        /// into themselves. This app keeps no secret for it.
        case signedInCommandLine

        /// A metered key this app keeps in the keychain.
        case apiKey

        /// A server on this machine. There is no credential.
        case localServer

        public var title: String {
            switch self {
            case .signedInCommandLine: "Subscription, signed in outside this app"
            case .apiKey:              "API key, metered"
            case .localServer:         "Local server"
            }
        }
    }

    public let provider      : ModelProvider
    public let authentication: Authentication

    /// Where a request goes, as a person can read it.
    public let destination: String

    /// The keychain account the secret is kept under, or nil when there is no
    /// secret to keep. It is a reference and never the secret: no record in
    /// the workspace holds a key or a token, and nothing that leaves this
    /// process carries one.
    public let credentialReference: String?

    public var id  : String { provider.rawValue }
    public var name: String { provider.title }

    /// What moving a worker from `previous` to this connection changes, as a
    /// sentence to consent to, or nil when nothing needs consent (§7.4).
    ///
    /// Consent is asked whenever the kind of authentication changes, in either
    /// direction: every such change is between local and cloud, or between a
    /// subscription and a metered key. Two keys, or two subscriptions, do not ask.
    public func consentNeeded(movingFrom previous: ProviderConnection) -> String? {
        guard previous.authentication != authentication else { return nil }
        let shared = "What you write to the worker, and its instructions, are sent to \(destination)"

        switch (previous.authentication, authentication) {
        case (.localServer, .apiKey):
            return "The worker runs on this Mac today. \(shared), billed per use with the key kept here."
        case (.localServer, .signedInCommandLine):
            return "The worker runs on this Mac today. \(shared), and count against that subscription."
        case (_, .localServer):
            return "The worker is answered by \(previous.destination) today. It will run on this Mac "
                + "through \(destination), and nothing more is sent to \(previous.destination)."
        case (.signedInCommandLine, .apiKey):
            return "The worker uses a subscription today. \(shared), billed per use with the key "
                + "kept here, so every turn from now on has a cost."
        default:
            return "The worker is billed per use today. \(shared), and count against the limits of "
                + "that subscription instead."
        }
    }

    public init(provider: ModelProvider, settings: ProviderSettings = ProviderSettings()) {
        self.provider = provider
        switch provider {
        case .codex:
            authentication      = .signedInCommandLine
            destination         = "the codex command line"
            credentialReference = nil

        case .claudeCode:
            authentication      = .signedInCommandLine
            destination         = "the claude command line"
            credentialReference = nil

        case .anthropic:
            authentication      = .apiKey
            destination         = "api.anthropic.com"
            credentialReference = provider.rawValue

        case .gemini:
            authentication      = .apiKey
            destination         = "generativelanguage.googleapis.com"
            credentialReference = provider.rawValue

        case .ollama:
            authentication      = .localServer
            destination         = settings.ollamaHost
            credentialReference = nil
        }
    }
}
