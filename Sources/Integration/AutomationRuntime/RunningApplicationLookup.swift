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

    /// The running application a word names: an exact bundle id first, then one of its names, then a
    /// name prefix, then a name that contains it ("Photoshop" for "Adobe Photoshop 2026"). Its names are
    /// those of `names(declared:bundleName:bundleURL:)`, so "Calculator" finds the application an Italian
    /// Mac shows as "Calcolatrice". Case and diacritics are ignored. Ambiguous matches are refused.
    public static func running(_ word: String) throws -> NSRunningApplication {
        let applications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let index = try chosen(word, among: applications.map { ($0.bundleIdentifier, names(of: $0)) })
        return applications[index]
    }

    /// The index of the application `word` names among `applications`, each a bundle id and its names,
    /// by the tiers of `running`. Throws when none matches, or when several share a prefix or containing tier.
    nonisolated public static func chosen(
        _ word            : String,
        among applications: [(bundleID: String?, names: [String])]
    ) throws -> Int {
        let wanted = folded(word)
        let named  = applications.map { $0.names.map(folded) }
        if let exact = applications.firstIndex(where: { $0.bundleID.map(folded) == wanted }) { return exact }
        if let exact = named.firstIndex(where: { $0.contains(wanted) }) { return exact }
        let prefixes = named.indices.filter { index in named[index].contains { $0.hasPrefix(wanted) } }
        let matches  = prefixes.isEmpty
            ? named.indices.filter { index in named[index].contains { $0.contains(wanted) } }
            : prefixes
        if matches.count == 1, let match = matches.first { return match }
        if matches.count > 1 { throw AutomationFailure("Application name is ambiguous: \(word). Use its bundle ID.") }
        throw AutomationFailure("No running application matches '\(word)'. Use windows to discover exact app names.")
    }

    /// Every name an application answers to: the one its bundle declares, its `CFBundleName` when
    /// a display name hides it, the name of its file and the name the Finder shows in the person's
    /// language. They differ for many applications: Visual Studio Code's bundle calls it "Code", and
    /// on an Italian Mac Calculator reads "Calcolatrice". Empty names and repeats are left out.
    nonisolated public static func names(declared name: String, bundleName: String?, bundleURL: URL?) -> [String] {
        var names = [name, bundleName ?? ""]
        if let url = bundleURL {
            names.append(url.deletingPathExtension().lastPathComponent)
            let shown = FileManager.default.displayName(atPath: url.path)
            names.append(shown.lowercased().hasSuffix(".app") ? String(shown.dropLast(4)) : shown)
        }
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// The names of a running application: its localized name, its unlocalized `CFBundleName` and
    /// those of its bundle. `object(forInfoDictionaryKey:)` would return the localized bundle name.
    static func names(of application: NSRunningApplication) -> [String] {
        let bundleName = application.bundleURL.flatMap { Bundle(url: $0) }?.infoDictionary?["CFBundleName"] as? String
        return names(
            declared  : application.localizedName ?? "",
            bundleName: bundleName,
            bundleURL : application.bundleURL
        )
    }

    nonisolated private static func folded(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
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
