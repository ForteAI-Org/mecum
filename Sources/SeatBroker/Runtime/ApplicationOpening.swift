//
//  ApplicationOpening.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 17/09/2026.
//

import AutomationRuntime
import Foundation

/// The name a planner wrote, turned into one application the seat can adopt,
/// and the list of names it chose from.
///
/// Both halves go through `isOpenable`, so what the model is offered and what
/// it is allowed to open cannot drift apart.
enum ApplicationOpening {

    /// Which installed applications the planner may open.
    ///
    /// Unset: every installed application is offered and openable. Opening an
    /// application on a model's say-so is the owner's decision, not this
    /// ticket's, and this predicate is where that decision goes. Narrowing it
    /// here narrows the list in the prompt and the resolution of a named
    /// application together, so constraining the capability is one edit in
    /// one file and nothing else has to know.
    static func isOpenable(_ app: TargetApp) -> Bool { true }

    /// How many names a prompt carries. Measured on this machine: 94 installed
    /// applications are 92 distinct names and 1025 characters, roughly 260
    /// tokens, repeated in every prompt of every decision. 150 stops a large
    /// library from doubling that, and costs nothing else: `resolve` reads the
    /// whole list, so a name past the cap is still openable, just unadvertised.
    static let catalogLimit = 150

    /// The names the prompts carry: names only, alphabetical, deduplicated,
    /// capped. A name is all the model needs to pick, and a bundle identifier
    /// or a path would triple the line for nothing.
    static func catalog(_ apps: [TargetApp], limit: Int = catalogLimit) -> String {
        let names = Set(apps.filter(isOpenable).map(\.name))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var line = names.prefix(limit).joined(separator: ", ")
        if names.count > limit {
            line += ", and \(names.count - limit) more that are not listed but can still be named."
        }
        return line
    }

    /// How a query matched an application, best first.
    private enum Match: Comparable {

        /// Its bundle identifier, exactly.
        case bundleID

        /// One of `names(of:)`, ignoring case and diacritics.
        case name

        /// One of them ignoring spaces and punctuation as well: "ProTools" for "Pro Tools".
        case normalizedName

        /// The starts of its words in order, or their initials: "pro to" and "PT" for "Pro Tools".
        case wordStarts

        /// A part of one of them, ignoring spaces and punctuation.
        case substring
    }

    /// The openable applications `query` matches, best match first and equal matches in
    /// `precedes` order; every openable application in that order when there is no query.
    ///
    /// `resolve` and the `apps` tool both read this one ranking, so what the model is offered
    /// and what it may open cannot disagree.
    static func ranked(_ query: String?, in apps: [TargetApp]) -> [TargetApp] {
        let wanted   = query.map(requested) ?? ""
        let openable = apps.filter(isOpenable)
        guard !wanted.isEmpty else { return openable.sorted(by: precedes) }
        return openable
            .compactMap { app in match(wanted, app).map { (app: app, match: $0) } }
            .sorted { $0.match == $1.match ? precedes($0.app, $1.app) : $0.match < $1.match }
            .map(\.app)
    }

    /// The one application `name` names, or a refusal the run can act on.
    ///
    /// Nothing is opened and nothing is released on the way out, so a refused
    /// name leaves the seat holding whatever it held and the run free to
    /// decide again. The best of `ranked` is taken only when it is
    /// unambiguous: alone in the best tier anything matched in, or the only
    /// one of that tier that is running. An exact name therefore wins
    /// outright, and a part of one name ("Chrome" for "Google Chrome") is
    /// meant when nothing matches better. Anything that names none or several
    /// is refused with what the model would need to correct itself.
    static func resolve(_ name: String, in apps: [TargetApp]) throws -> TargetApp {
        let wanted = requested(name)
        guard !wanted.isEmpty else {
            throw SeatBrokerError.applicationNotResolved("No application was named to open.")
        }
        let candidates = ranked(wanted, in: apps)
        guard let best = candidates.first.flatMap({ match(wanted, $0) }) else {
            throw SeatBrokerError.applicationNotResolved(
                "\"\(wanted)\" is not an application installed on this machine; "
                    + "call apps with a shorter query, then open_session with the bundleID it lists.")
        }
        let tier    = candidates.prefix { match(wanted, $0) == best }
        let running = tier.filter(\.isRunning)
        if tier.count == 1, let only = tier.first { return only }
        if running.count == 1, let only = running.first { return only }
        throw ambiguity(wanted, Array(tier))
    }

    /// The order among equally good matches: running first, then the most recently used, then the
    /// shorter name, so a base product comes before its "Developer" or "Beta", then alphabetical.
    static func precedes(_ a: TargetApp, _ b: TargetApp) -> Bool {
        if a.isRunning != b.isRunning { return a.isRunning }
        if a.lastUsed != b.lastUsed { return (a.lastUsed ?? .distantPast) > (b.lastUsed ?? .distantPast) }
        if a.name.count != b.name.count { return a.name.count < b.name.count }
        let order = a.name.localizedCaseInsensitiveCompare(b.name)
        return order == .orderedSame ? a.bundleID < b.bundleID : order == .orderedAscending
    }

    /// One candidate as a refusal lists it: its name, then its bundle identifier, its version when
    /// the bundle declares one and whether it is running.
    static func described(_ app: TargetApp) -> String {
        "\(app.name) — \(app.bundleID)" + (app.version.map { " \($0)" } ?? "") + (app.isRunning ? " (running)" : "")
    }

    /// An application that opened and then could not take the seat: not
    /// movable, no settable position, too large for the background display and
    /// unwilling to shrink. Choosing freely from what is installed makes this
    /// an ordinary outcome, and without the name it reads to the person as
    /// "no application is adopted", two decisions later, about a window they
    /// never saw. The driver's own sentence says which of the reasons it was.
    static func notSeated(_ app: TargetApp, cause: any Error) -> SeatBrokerError {
        .driver("\(app.name) opened but could not be seated on the background display. "
            + cause.localizedDescription)
    }

    /// What became of an application that opened and was never seated: quit again when this open
    /// launched it, and left running when it was already open, since that one is the person's.
    static func unseated(_ name: String, wasLaunched: Bool, wasQuit: Bool) -> String {
        switch (wasLaunched, wasQuit) {
            case (true, true) : "\(name) was closed again, since this open had launched it."
            case (true, false): "\(name) could not be closed again and is still running; quit it yourself."
            case (false, _)   : "\(name) was left running, since it was already open."
        }
    }

    /// Every name an application answers to: the one its bundle declares, its `CFBundleName` when
    /// a display name hides it, the name of its file and the name the Finder shows in the person's
    /// language. They differ for many applications: Visual Studio Code's bundle calls it "Code", and
    /// on an Italian Mac Calculator reads "Calcolatrice". Its bundle identifier is matched as well.
    static func names(of app: TargetApp) -> [String] {
        RunningApplicationLookup.names(declared: app.name, bundleName: app.bundleName, bundleURL: app.bundleURL)
    }

    private static let comparison: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    private static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: comparison) == .orderedSame
    }

    /// A name as the model wrote it, trimmed and without an ".app" suffix.
    private static func requested(_ name: String) -> String {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return wanted.lowercased().hasSuffix(".app") ? String(wanted.dropLast(4)) : wanted
    }

    /// How well `wanted` names `app`, or nil when it does not name it at all.
    private static func match(_ wanted: String, _ app: TargetApp) -> Match? {
        if same(app.bundleID, wanted) { return .bundleID }
        let names = names(of: app)
        if names.contains(where: { same($0, wanted) }) { return .name }
        let key = normalized(wanted)
        guard !key.isEmpty else { return nil }
        let keys = names.map(normalized)
        if keys.contains(key) { return .normalizedName }
        if names.contains(where: { startsWords(key[...], of: words(of: $0)[...]) }) { return .wordStarts }
        if keys.contains(where: { $0.contains(key) }) { return .substring }
        return nil
    }

    /// Whether `key` splits, in order, into the starts of different words: "pt" and "proto" both
    /// do for "pro tools", taking "p" or "pro" from its first word and "t" or "to" from its second.
    private static func startsWords(_ key: Substring, of words: ArraySlice<Substring>) -> Bool {
        guard !key.isEmpty else { return true }
        for index in words.indices {
            let shared = zip(key, words[index]).prefix { $0 == $1 }.count
            for length in stride(from: shared, to: 0, by: -1)
            where startsWords(key.dropFirst(length), of: words[(index + 1)...]) {
                return true
            }
        }
        return false
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Letters and digits only, folded: "Pro Tools" and "ProTools" are both "protools".
    private static func normalized(_ text: String) -> String {
        folded(text).filter { $0.isLetter || $0.isNumber }
    }

    private static func words(of text: String) -> [Substring] {
        folded(text).split { !$0.isLetter && !$0.isNumber }
    }

    /// Six candidates, because this sentence is read back to the model as history in every later
    /// prompt and a list of forty would crowd out the scene. The bundle identifier is what tells
    /// two applications of one name apart, and it is what `open_session` takes exactly.
    private static func ambiguity(_ wanted: String, _ matches: [TargetApp]) -> SeatBrokerError {
        let shown = matches.prefix(6).map(described).joined(separator: "; ")
        return .applicationNotResolved(
            "\"\(wanted)\" names \(matches.count) installed applications: \(shown). "
                + "Choose from the conversation's context; if it does not say which one, ask the person "
                + "which one they mean, naming these; then call open_session with the chosen bundleID.")
    }
}
