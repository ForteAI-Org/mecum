//
//  RunningApplicationLookupTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/10/2026.
//

import AutomationRuntime
import Foundation
import Testing

/// The choice of one running application by a word, over Calculator as an Italian Mac names it.
@Suite("Choosing a running application by name")
struct RunningApplicationLookupTests {

    typealias Application = (bundleID: String?, names: [String])

    static let calculator: Application = (
        "com.apple.calculator",
        RunningApplicationLookup.names(
            declared  : "Calcolatrice",
            bundleName: nil,
            bundleURL : URL(fileURLWithPath: "/System/Applications/Calculator.app")
        )
    )

    static let finder: Application = ("com.apple.finder", ["Finder"])

    @Test("Calculator answers to its file name, its localized name and its bundle ID")
    func everyNameChoosesIt() throws {
        for word in ["Calculator", "calculator", "Calcolatrice", "com.apple.calculator"] {
            #expect(try RunningApplicationLookup.chosen(word, among: [Self.finder, Self.calculator]) == 1)
        }
    }

    @Test("an exact bundle ID wins before a name, and a shared prefix is refused")
    func tiersAndAmbiguity() throws {
        let namedLikeAnID: Application = (nil, ["com.apple.calculator"])
        let among = [namedLikeAnID, Self.calculator]
        #expect(try RunningApplicationLookup.chosen("com.apple.calculator", among: among) == 1)
        let failure = #expect(throws: AutomationFailure.self) {
            try RunningApplicationLookup.chosen("Calc", among: [Self.calculator, (nil, ["Calc Pro"])])
        }
        #expect(failure?.description.hasPrefix("Application name is ambiguous") == true)
    }
}
