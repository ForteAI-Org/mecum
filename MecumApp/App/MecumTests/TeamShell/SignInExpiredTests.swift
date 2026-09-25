//
//  SignInExpiredTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import Foundation
import ModelTransports
import Testing
@testable import Mecum

/// A turn that failed because its command line is signed out is told apart from any other failure,
/// in the words the command lines use, and the alert, the failure card and the connection's state
/// all say how to sign in again.
@MainActor
@Suite("A signed out command line")
struct SignInExpiredTests {

    /// What reached a person from Claude Code with an expired token.
    private static let expired = "Failed to authenticate. API Error: 401 OAuth access token has expired. "
        + "Re-authenticate to continue."

    @Test func claudesExpiredTokenAsksToSignInAgain() throws {
        let issue = try #require(TeamModel.signInExpired(provider: .claudeCode, reason: Self.expired))
        #expect(issue.title == "Sign In to Claude Code Again")
        #expect(issue.message.contains("run claude and type /login"))
        #expect(issue.technicalDetails == Self.expired)
    }

    @Test func codexSignedOutAsksToSignInAgain() throws {
        let reason = "unexpected status 401 Unauthorized: Your access token could not be refreshed. Please log in again."
        let issue  = try #require(TeamModel.signInExpired(provider: .codex, reason: reason))
        #expect(issue.title == "Sign In to Codex Again")
        #expect(issue.message.contains("codex login"))
    }

    @Test func aBare401IsASignInAndAnyOtherFailureIsNot() {
        #expect(SignInFailure.isSignedOut("API Error: 401"))
        #expect(SignInFailure.isSignedOut("HTTP 401: {}"))
        #expect(!SignInFailure.isSignedOut("Provider exited with status 1."))
        #expect(!SignInFailure.isSignedOut("Timed out after 4010 ms."))
        #expect(TeamModel.signInExpired(provider: .claudeCode, reason: "Provider exited with status 1.") == nil)
        #expect(TeamModel.signInExpired(provider: .codex, reason: "You've hit your usage limit.") == nil)
    }

    @Test func theFailureCardSaysHowToSignInInsteadOfToRetry() {
        let item = TranscriptItem(
            id            : .event(UUID()),
            kind          : .executionFailed(reason: Self.expired),
            date          : Date(),
            authorWorkerID: UUID(),
            continuesGroup: false
        )
        let signedOut = RowPreparation.preparedText(
            for           : item,
            workerName    : "DaVinci",
            workerProvider: .claudeCode,
            pipeline      : MarkdownContent()
        ).string
        #expect(signedOut.contains("Claude Code is signed out, so DaVinci couldn’t respond."))
        #expect(signedOut.contains("Open Terminal, run claude and type /login. Then send your message again."))
        #expect(signedOut.contains(Self.expired))
        #expect(!signedOut.contains("retry"))

        // A provider that is not a command line, or none, keeps the card that asks to send again.
        for provider in [ModelProvider.anthropic, nil] {
            let other = RowPreparation.preparedText(
                for           : item,
                workerName    : "DaVinci",
                workerProvider: provider,
                pipeline      : MarkdownContent()
            ).string
            #expect(other.contains("DaVinci couldn’t finish the response. Send your message again to retry."))
        }
    }

    @Test func aRefusedCommandLineConnectionSaysHowToSignIn() {
        let refused = ConnectionState.credentialRejected(detail: Self.expired)
        #expect(refused.message(for: .claudeCode) == "Open Terminal, run claude and type /login.")
        #expect(ConnectionState.credentialMissing.message(for: .codex).contains("codex login"))
        #expect(refused.message(for: .anthropic) == refused.message)
        #expect(ConnectionState.ready.message(for: .claudeCode) == ConnectionState.ready.message)
    }
}
