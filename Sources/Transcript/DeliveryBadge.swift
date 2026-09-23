//
//  DeliveryBadge.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import Workspace

/// DeliveryBadge is the one mark a person's message carries when its delivery
/// went wrong. A message that went fine carries none and no status text.
///
/// A badge is a symbol, so it reads without colour (§3.3); what it means is
/// spoken by the row's accessibility label, which names every delivery state
/// (§11.5). An interrupted worker reply carries no badge: the Stopped or
/// failure card that follows it already says so, and a fact is shown once.
public enum DeliveryBadge: Sendable, Hashable {

    /// The turn this message started failed or was stopped.
    case interrupted

    /// Saved here and not handed to any backend yet.
    case notSent

    /// How long a message may stay saved and unsent before it is marked.
    ///
    /// Every send passes through saved: the turn moves the message to sent
    /// after a few local writes, milliseconds on an idle store. 1.5 s leaves a
    /// busy store room for that without a flash, and is still short enough
    /// that a message nothing will send is marked almost at once.
    public static let unsentGrace: TimeInterval = 1.5

    /// The badge a person's message with `delivery`, saved at `savedAt`,
    /// carries at `now`, or nil when it went fine or is still on its way.
    public init?(_ delivery: MessageDelivery, savedAt: Date, now: Date) {
        switch delivery {
        case .interrupted:
            self = .interrupted
        case .savedLocally where now.timeIntervalSince(savedAt) >= Self.unsentGrace:
            self = .notSent
        case .savedLocally, .pending, .sentToBackend, .responding, .completed:
            return nil
        }
    }

    /// The badge `kind` carries, or nil for a row that went fine or is not a
    /// person's message.
    public init?(_ kind: TranscriptItem.Kind) {
        guard case .personMessage(_, _, let badge?) = kind else { return nil }
        self = badge
    }

    /// An SF Symbol name. Each badge has its own shape.
    public var symbolName: String {
        switch self {
        case .interrupted: "exclamationmark.circle"
        case .notSent:     "clock"
        }
    }
}
