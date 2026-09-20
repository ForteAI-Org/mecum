//
//  ApplicationLookup.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import AppKit
import LiveScenes
import SeatDriving

/// ApplicationLookup resolves the word on the command line to a running application, and a process
/// id back to its identity for the scene provider.
public enum RunningApplicationLookup {

    /// The running application a word names: an exact bundle id first, then a case-insensitive name,
    /// then a name prefix. Ambiguous prefixes are refused.
    public static func running(_ word: String) throws -> NSRunningApplication {
        let applications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let lower = word.lowercased()
        if let exact = applications.first(where: { $0.bundleIdentifier?.lowercased() == lower }) { return exact }
        if let named = applications.first(where: { $0.localizedName?.lowercased() == lower }) { return named }
        let prefixes = applications.filter { $0.localizedName?.lowercased().hasPrefix(lower) == true }
        if prefixes.count == 1, let match = prefixes.first { return match }
        if prefixes.count > 1 { throw AutomationFailure("Application name is ambiguous: \(word). Use its bundle ID.") }
        throw AutomationFailure("No running application matches '\(word)'. Use windows to discover exact app names.")
    }

    /// The identity of a process, for the foreground scene provider. Nonisolated: the provider asks from
    /// its own task, and `NSRunningApplication` lookup by process id is safe off the main actor.
    nonisolated public static func identity(of processID: pid_t) -> LiveScenes.ApplicationIdentity? {
        guard let application = NSRunningApplication(processIdentifier: processID) else { return nil }
        return LiveScenes.ApplicationIdentity(
            bundleID: application.bundleIdentifier ?? "pid.\(processID)",
            name    : application.localizedName ?? "pid \(processID)"
        )
    }

    /// The same identity, in the Seat provider's type.
    nonisolated public static func identity(of processID: pid_t) -> SeatDriving.ApplicationIdentity? {
        guard let application = NSRunningApplication(processIdentifier: processID) else { return nil }
        return SeatDriving.ApplicationIdentity(
            bundleID: application.bundleIdentifier ?? "pid.\(processID)",
            name    : application.localizedName ?? "pid \(processID)"
        )
    }
}
