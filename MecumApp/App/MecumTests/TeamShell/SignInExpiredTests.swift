//
//  SignInExpiredTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ModelTransports
import Testing
@testable import Mecum

/// A turn that failed because its command line is signed out is told apart from any other failure,
/// in the words the command lines use, and the alert says how to sign in again.
@MainActor
@Suite("A signed out command line")
struct SignInExpiredTests {

    @Test func claudesExpiredTokenAsksToSignInAgain() throws {
        let reason = "Failed to authenticate. API Error: 401 OAuth access token has expired. Re-authenticate to continue."
        let issue  = try #require(TeamModel.signInExpired(provider: .claudeCode, reason: reason))
        #expect(issue.title == "Sign In to Claude Again")
        #expect(issue.message.contains("run claude, type /login"))
        #expect(issue.technicalDetails == reason)
    }

    @Test func codexSignedOutAsksToSignInAgain() throws {
        let reason = "unexpected status 401 Unauthorized: Your access token could not be refreshed. Please log in again."
        let issue  = try #require(TeamModel.signInExpired(provider: .codex, reason: reason))
        #expect(issue.title == "Sign In to Codex Again")
    }

    @Test func anyOtherFailureRaisesNoSignInAlert() {
        #expect(TeamModel.signInExpired(provider: .claudeCode, reason: "Provider exited with status 1.") == nil)
        #expect(TeamModel.signInExpired(provider: .codex, reason: "You've hit your usage limit.") == nil)
    }
}
