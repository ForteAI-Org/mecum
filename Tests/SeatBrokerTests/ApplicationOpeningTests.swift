//
//  ApplicationOpeningTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 17/09/2026.
//

import Foundation
import Testing
@testable import SeatBroker

private func app(_ name: String, running: Bool = false) -> TargetApp {
    TargetApp(pid: running ? 42 : nil, bundleID: "com.example.\(name)", name: name,
              bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"), windows: [])
}

private let installed = [app("Photos"), app("Google Chrome"), app("Preview"), app("Pages"), app("Café")]

@Test func resolvesAnInstalledApplicationHoweverTheNameIsWritten() throws {
    #expect(try ApplicationOpening.resolve("Photos", in: installed).name == "Photos")
    #expect(try ApplicationOpening.resolve("  photos ", in: installed).name == "Photos")
    #expect(try ApplicationOpening.resolve("Photos.app", in: installed).name == "Photos")
    #expect(try ApplicationOpening.resolve("Cafe", in: installed).name == "Café")
    // Not a name anybody has: one installed name contains it, so it is meant.
    #expect(try ApplicationOpening.resolve("Chrome", in: installed).name == "Google Chrome")
}

@Test func refusesANameThatMatchesNothingAndOneThatMatchesSeveral() {
    func sentence(for name: String, in apps: [TargetApp] = installed) -> String {
        do {
            let resolved = try ApplicationOpening.resolve(name, in: apps)
            Issue.record("\(name) resolved to \(resolved.name) instead of being refused")
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    let missing = sentence(for: "Microsoft Word")
    #expect(missing.contains("\"Microsoft Word\" is not an application installed on this machine"))
    #expect(missing.contains("listed in the prompt"))

    // "P" is in Photos, Preview and Pages: the run is told which, so the next
    // decision can name one of them instead.
    let several = sentence(for: "P")
    #expect(several.contains("\"P\" names 3 installed applications"))
    #expect(several.contains("Pages, Photos, Preview"))

    #expect(sentence(for: "   ").contains("No application was named"))
}

@Test func theCatalogIsNamesOnlyAndSaysWhatItLeftOut() {
    let line = ApplicationOpening.catalog(installed)
    #expect(line == "Café, Google Chrome, Pages, Photos, Preview")
    #expect(!line.contains("com.example"))
    #expect(!line.contains("/Applications"))

    // Two installs of one name are one offer; resolving the name is where
    // that ambiguity is answered, not here.
    #expect(ApplicationOpening.catalog([app("Photos"), app("Photos")]) == "Photos")

    let capped = ApplicationOpening.catalog(installed, limit: 2)
    #expect(capped.hasPrefix("Café, Google Chrome"))
    #expect(capped.contains("3 more that are not listed but can still be named"))
}

@Test func anApplicationThatCannotBeSeatedIsNamedWithTheDriverSentence() {
    let cause = SeatBrokerError.driver("The window is 3000×2000 pt and does not fit in the "
        + "1512×982 pt background display. Make it smaller and try again.")
    let error = ApplicationOpening.notSeated(app("Photos"), cause: cause)
    let message = error.localizedDescription
    #expect(message.contains("Photos opened but could not be seated on the background display."))
    #expect(message.contains("does not fit in the 1512×982 pt background display"))
}
