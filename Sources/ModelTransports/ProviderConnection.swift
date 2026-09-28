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
/// How a worker on the connection answers is `WorkerAnswer`'s to say, not
/// this value's.
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
            case .signedInCommandLine: "Subscription"
            case .apiKey:              "API Key"
            case .localServer:         "Local Server"
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
        switch (previous.authentication, authentication) {
        case (.localServer, .apiKey):
            return "Messages and worker instructions will be sent to \(destination). Usage may be billed to the API key stored in Keychain."
        case (.localServer, .signedInCommandLine):
            return "Messages and worker instructions will be sent to \(destination) and will count toward that subscription."
        case (_, .localServer):
            return "New messages and worker instructions will run locally through \(destination). Mecum will stop sending them to \(previous.destination)."
        case (.signedInCommandLine, .apiKey):
            return "Messages and worker instructions will be sent to \(destination). New turns may be billed to the API key stored in Keychain."
        default:
            return "Messages and worker instructions will be sent to \(destination) and will count toward that subscription instead of API usage."
        }
    }

    public init(provider: ModelProvider, settings: ProviderSettings = ProviderSettings()) {
        self.provider = provider
        switch provider {
        case .codex:
            authentication      = .signedInCommandLine
            destination         = "the Codex command-line tool"
            credentialReference = nil

        case .claudeCode:
            authentication      = .signedInCommandLine
            destination         = "the Claude command-line tool"
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
