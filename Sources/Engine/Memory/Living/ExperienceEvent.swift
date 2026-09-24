//
//  ExperienceEvent.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import EngineCore
import Foundation

/// ExperienceEvent is one outcome in an experience's history: a verified success, a contradiction,
/// a verified no-op, or an uncertain attempt. History is append-only; counters derive from it.
///
/// `id` is the event's idempotency key, chosen by the recorder before the write, so a write whose
/// result was lost can be repeated without counting twice. It identifies the write, not the memory.
public struct ExperienceEvent: Sendable, Equatable, Codable {

    public let id: String
    public let subject: Subject
    public let outcome: Outcome
    public let at: Date

    public init(id: String, subject: Subject, outcome: Outcome, at: Date) {
        self.id      = id
        self.subject = subject
        self.outcome = outcome
        self.at      = at
    }

    /// Subject is what the event is about, and only what the recorder can actually attribute.
    public enum Subject: Sendable, Equatable, Codable {
        /// A step in a context: the experience with this draft's natural key. Only a verified
        /// success creates it; any other outcome joins it only when it already exists.
        case step(ExperienceDraft)
        /// An experience the recorder knows by identity, such as the one a correction refers to.
        case experience(ExperienceID)
        /// An attempt linked to no experience, kept for diagnosis without contradicting any.
        case unattributed(WindowContext)
    }

    /// Outcome keeps four meanings apart. Only a success strengthens and only a contradiction
    /// weakens; a no-op and an uncertain attempt are history without counting.
    public enum Outcome: Sendable, Equatable, Codable {
        /// The step changed the control to the requested item, with the proof.
        case verified(DropdownEvidence)
        /// The step is known not to do what the experience says.
        case contradicted(Contradiction)
        /// The control already read the requested item: verified, but nothing was learned.
        case noChange(DropdownEvidence)
        /// Nothing can be concluded, such as a readback that saw nothing.
        case uncertain(Uncertainty)

        /// The outcome a selection's evidence supports on its own. A readback of another value
        /// contradicts; a missing reading is uncertain, never a contradiction.
        public init(_ evidence: DropdownEvidence) {
            switch evidence.change {
                case .changed   : self = .verified(evidence)
                case .alreadySet: self = .noChange(evidence)
                case .unverified:
                    switch evidence.readback {
                        case .window(let value), .controlCrop(let value):
                            self = .contradicted(.readbackShowed(value))
                        case .unreadable(let why):
                            self = .uncertain(.readbackUnavailable(why))
                    }
            }
        }
    }

    /// Contradiction is positive evidence against an experience.
    public enum Contradiction: Sendable, Equatable, Codable {
        /// After the step, the control was read showing this other value.
        case readbackShowed(String)
        /// The user said the remembered step is wrong.
        case userCorrection
    }

    /// Uncertainty is an attempt that proves neither way.
    public enum Uncertainty: Sendable, Equatable, Codable {
        /// The control's value could not be read back after the menu closed.
        case readbackUnavailable(DropdownReadback.Unreadable)
        /// The turn was interrupted or cancelled before its outcome was known.
        case interrupted
        /// A failure, such as a permission or transport error, that says nothing about the step.
        case failureNotAttributable
    }
}
