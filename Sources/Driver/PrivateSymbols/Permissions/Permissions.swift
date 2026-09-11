//
//  Permissions.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import ApplicationServices
import CoreGraphics
import Foundation
import SeatCore

/// Permissions is the kit's whole relationship with TCC: it looks, and it asks
/// only when it is told to. `preflight` never prompts, so it is safe in a
/// watchdog and in a status pill; `request` prompts, so it belongs behind a
/// control the person pressed. A library that prompts on its own is
/// indistinguishable from a broken app, and the person cannot tell which one
/// asked.
///
/// The three grants are not interchangeable. Post Event and Accessibility are
/// separate switches in System Settings even though both live under Privacy and
/// Security, and Screen Recording is only re-read at launch: a fresh grant does
/// not reach a running process.
nonisolated public enum Permissions {

    /// True when the grant is already there. Never prompts, never blocks.
    public static func preflight(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .postEvent:       CGPreflightPostEventAccess()
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .accessibility:   AXIsProcessTrusted()
        }
    }

    /// Asks the person, showing the system prompt. The return value is the
    /// state right after the call, which for Screen Recording is normally still
    /// `false`: macOS only hands the grant to the next launch.
    @discardableResult
    public static func request(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .postEvent:
            return CGRequestPostEventAccess()
        case .screenRecording:
            return CGRequestScreenCaptureAccess()
        case .accessibility:
            // The key is spelled out rather than read from
            // `kAXTrustedCheckOptionPrompt`, which the SDK exports as a mutable
            // global and is therefore not concurrency safe.
            let options = ["AXTrustedCheckOptionPrompt": kCFBooleanTrue as Any] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
    }

    /// The first grant of the list that is missing, in the order given.
    public static func firstMissing(of kinds: [PermissionKind]) -> PermissionKind? {
        kinds.first { !preflight($0) }
    }

    /// The first grant this Facility cannot work without and does not have.
    public static func firstMissing(for facility: Facility) -> PermissionKind? {
        firstMissing(of: facility.permissions)
    }
}
