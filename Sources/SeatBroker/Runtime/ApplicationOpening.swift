//
//  ApplicationOpening.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 17/09/2026.
//

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

    /// The one application `name` names, or a refusal the run can act on.
    ///
    /// Nothing is opened and nothing is released on the way out, so a refused
    /// name leaves the seat holding whatever it held and the run free to
    /// decide again. An exact name wins outright; otherwise a name that
    /// appears in exactly one installed name is taken as meant ("Chrome" for
    /// "Google Chrome"), and anything that names none or several is refused
    /// with what the model would need to correct itself.
    static func resolve(_ name: String, in apps: [TargetApp]) throws -> TargetApp {
        var wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if wanted.lowercased().hasSuffix(".app") { wanted = String(wanted.dropLast(4)) }
        guard !wanted.isEmpty else {
            throw SeatBrokerError.applicationNotResolved("No application was named to open.")
        }
        let openable = apps.filter(isOpenable)
        let exact = openable.filter { same($0.name, wanted) }
        if let only = exact.first, exact.count == 1 { return only }
        if exact.count > 1 { throw ambiguity(wanted, exact) }

        let partial = openable.filter { $0.name.range(of: wanted, options: comparison) != nil }
        if let only = partial.first, partial.count == 1 { return only }
        if partial.count > 1 { throw ambiguity(wanted, partial) }
        throw SeatBrokerError.applicationNotResolved(
            "\"\(wanted)\" is not an application installed on this machine; "
                + "name one of the installed applications listed in the prompt, exactly as it is written there.")
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

    private static let comparison: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    private static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: comparison) == .orderedSame
    }

    /// Six names, because this sentence is read back to the model as history in
    /// every later prompt and a list of forty would crowd out the scene.
    private static func ambiguity(_ wanted: String, _ matches: [TargetApp]) -> SeatBrokerError {
        let names = matches.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let shown = names.prefix(6).joined(separator: ", ")
        return .applicationNotResolved(
            "\"\(wanted)\" names \(names.count) installed applications (\(shown)); "
                + "name the one you mean exactly as it is written.")
    }
}
