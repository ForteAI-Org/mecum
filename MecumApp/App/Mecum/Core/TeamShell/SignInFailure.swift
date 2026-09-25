//
//  SignInFailure.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import Foundation
import ModelTransports

/// SignInFailure recognises a command line agent that is no longer signed in, and says how to sign
/// in again. The alert, the conversation's failure card and the connection's state all ask it, so
/// the three never disagree on what the person has to do.
///
/// The command lines say so only in their error's words, which are matched here. Claude Code's
/// expired OAuth token reached a person as "Failed to authenticate. API Error: 401 OAuth access
/// token has expired. Re-authenticate to continue."; Codex refuses a missing or rejected ChatGPT
/// sign-in in its own words. A 401 from either is a refused sign-in, whatever words come with it.
nonisolated enum SignInFailure {

    /// True when `reason`, a command line's failure, says it is signed out.
    static func isSignedOut(_ reason: String) -> Bool {
        let text = reason.lowercased()
        return signals.contains(where: text.contains)
            || text.range(of: #"\b401\b"#, options: .regularExpression) != nil
    }

    private static let signals = [
        "oauth access token has expired",
        "failed to authenticate",
        "authentication_error",
        "please run /login",
        "invalid api key",
        "not logged in",
        "unauthorized",
        "token has expired",
        "sign in again",
        "log in again",
        "re-authenticate",
    ]

    /// What the person does to sign `provider` in again, nil for a provider that is not a command
    /// line: an API key or a local server is not signed in to.
    static func steps(for provider: ModelProvider) -> String? {
        switch provider {
        case .claudeCode:                   "Open Terminal, run claude and type /login."
        case .codex:                        "Open Terminal and run codex login, or sign in to ChatGPT."
        case .anthropic, .gemini, .ollama:  nil
        }
    }

    /// The command line's own name, which is what the person runs: "Claude" alone reads as the API.
    static func name(of provider: ModelProvider) -> String {
        provider == .claudeCode ? "Claude Code" : provider.title
    }
}

extension ConnectionState {

    /// What the person does next about `provider`'s connection. A command line that is signed out
    /// or refused says how to sign in, where the general sentence would only ask for credentials.
    func message(for provider: ModelProvider) -> String {
        switch self {
        case .credentialMissing, .credentialRejected:
            SignInFailure.steps(for: provider) ?? message
        default:
            message
        }
    }
}
