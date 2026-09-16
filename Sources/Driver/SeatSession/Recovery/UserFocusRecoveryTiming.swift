//
//  UserFocusRecoveryTiming.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

/// Durations start at activation handling, not at the unknown OS focus change.
/// Zero may denote an unmeasured phase or a duration below clock resolution.
/// Request completion is an offset;
/// it does not prove that the user application has processed its focus events.
nonisolated public struct UserFocusRecoveryTiming: Sendable, Equatable, Codable {
    /// Origin and observer receipt use the same monotonic clock as detection.
    public enum ActivationSource: String, Sendable, Codable {
        case workspaceNotification, contextMenuPoll, unspecified
    }
    public internal(set) var activationSource: ActivationSource?
    public internal(set) var notificationReceivedAtUptimeNanoseconds: UInt64?
    public internal(set) var destinationPreparationNanoseconds: UInt64 = 0
    /// Work before input; excluded from interruption and request-completion times.
    public internal(set) var actionPreparationNanoseconds: UInt64 = 0
    public internal(set) var preparedIdentityNanoseconds: UInt64 = 0
    public internal(set) var preparedWindowsNanoseconds: UInt64 = 0
    public internal(set) var preparedSnapshotAgeNanoseconds: UInt64 = 0
    public internal(set) var detectedAtUptimeNanoseconds: UInt64 = 0
    public internal(set) var pauseAndPublicationNanoseconds: UInt64 = 0
    public internal(set) var environmentNanoseconds: UInt64 = 0
    public internal(set) var adoptedWindowsNanoseconds: UInt64 = 0
    public internal(set) var visibleWindowsNanoseconds: UInt64 = 0
    public internal(set) var destinationNanoseconds: UInt64 = 0
    public internal(set) var finalGuardsNanoseconds: UInt64 = 0
    public internal(set) var ownerLookupNanoseconds: UInt64 = 0
    public internal(set) var psnLookupNanoseconds: UInt64 = 0
    public internal(set) var activationNanoseconds: UInt64 = 0
    public internal(set) var firstKeyNanoseconds: UInt64 = 0
    public internal(set) var secondKeyNanoseconds: UInt64 = 0
    public internal(set) var requestFinishedNanoseconds: UInt64 = 0
}
