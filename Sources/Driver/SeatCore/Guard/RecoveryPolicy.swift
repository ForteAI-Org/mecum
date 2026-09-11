//
//  RecoveryPolicy.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

/// RecoveryPolicy is the budget of a seat's recovery, and the one place that
/// refuses to recover at all. A recovery never authorizes repeating an input
/// whose effect is unknown: replaying it could duplicate a real action, so an
/// unconfirmed Command turns a recoverable Issue into a failed seat.
public struct RecoveryPolicy: Sendable, Equatable {

    /// How many recovery episodes a seat gets before `recoveryExhausted`.
    public static let maximumEpisodes = 3

    /// How many episodes have started so far.
    public private(set) var attempts = 0

    public init() {}

    /// begin opens one recovery episode, or throws the reason it cannot.
    /// A critical Issue is terminal; an input posted with an `unknown`
    /// confirmation is `ambiguousEffect`; past the budget it is
    /// `recoveryExhausted`. `absent` is as safe as `observed` here: the caller
    /// verified that nothing happened, so it may send again afterwards.
    public mutating func begin(
        issues        : [SeatIssue],
        inputWasPosted: Bool,
        confirmation  : EffectConfirmation
    ) throws {
        
        if issues.contains(where: \.isCritical) {
            throw SeatInterruption(issues: issues)
        }
        
        if inputWasPosted && confirmation == .unknown {
            throw SeatInterruption(issues: [.ambiguousEffect])
        }
        
        guard attempts < Self.maximumEpisodes else {
            throw SeatInterruption(issues: [.recoveryExhausted])
        }
        
        attempts += 1
    }
}
