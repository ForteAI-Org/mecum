//
//  ToolCopyTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/10/2026.
//

import Foundation
import Testing
@testable import Mecum

/// Copying a whole tool line: a release build gives the words the line shows,
/// a Debug build the records, compact enough to paste into a report.
@Suite("Tool copy: shown words in release, compacted records in debug")
struct ToolCopyTests {

    /// A scene as a JSON string, as the host renders it: a header line, then 35 elements.
    static let scene = #""app: Calcolatrice (com.apple.calculator): \"Calcolatrice\"\nviewport: 230x408\n"#
        + #"elements (35):\n"# + (1...35).map { #"  button \#($0)\n"# }.joined() + #"""#

    /// The scene a debug copy gives in its place.
    static let shortScene = #""app: Calcolatrice (com.apple.calculator): \"Calcolatrice\" · 35 elements""#

    /// The session the host names, as it records it.
    static let session = #""515D9A2C-7E41-4B0F-9C3D-2F6A8B1E4D70""#

    /// What a batch step's result carries as its observation.
    static func observation(revision: Int) -> String {
        #"{"session":"# + session + #","scene":"# + scene + #","revision":\#(revision),"#
            + #""observedAt":"2026-10-01T08:53:3\#(revision)Z"}"#
    }

    /// The Calculator turn as the host recorded it, keys in its order: a look
    /// around, the app opened, a three-step batch stopped at step 2.
    static let calculator: [String] = [
        #"→ status {}"#,
        #"← status {"session":null,"permissions":{"screenRecording":true,"accessibility":true,"postEvent":true}}"#,
        #"→ windows {"app":"Calcolatrice"}"#,
        #"← windows {"applications":[{"pid":13776,"windows":[{"id":27741,"title":"Calcolatrice"}],"#
            + #""name":"Calcolatrice","bundleID":"com.apple.calculator"}]}"#,
        #"→ open_session {"app":"com.apple.calculator","window":"Calcolatrice"}"#,
        #"← open_session {"observedAt":"2026-10-01T08:53:31Z","session":"# + session + #",""#
            + #"revision":7,"scene":"# + scene + "}",
        #"→ batch {"session":"# + session + #","steps":["#
            + #"{"target":"7","verb":"click","operation":"act"},"#
            + #"{"target":"Nonexistent","verb":"click","operation":"act"},"#
            + #"{"target":"8","verb":"click","operation":"act"}]}"#,
        #"← batch step 1 {"status":"found_acted","observation":"# + observation(revision: 8)
            + #","message":"clicked '7': reveals elements","session":"# + session + "}",
        #"← batch step 2 {"message":"no element 'Nonexistent' in Calcolatrice","observation":"#
            + observation(revision: 9) + #","session":"# + session + #","status":"honest_miss"}"#,
        #"← batch {"requested":3,"attemptedSteps":2,"steps":["#
            + #"{"status":"found_acted","observation":"# + observation(revision: 8) + "},"
            + #"{"status":"honest_miss","observation":"# + observation(revision: 9) + "}],"
            + #""verifiedSteps":1,"status":"stopped"}"#,
    ]

    private static func copy(_ lines: [String], isExpanded: Bool = true, detailed: Bool) -> String {
        ToolStep.copyText(
            of        : lines,
            isExpanded: isExpanded,
            ending    : .completed,
            detailed  : detailed
        )
    }

    @Test("A collapsed line copies its summary alone, an opened one the summary then its steps")
    func releaseCopy() {
        #expect(Self.copy(Self.calculator, isExpanded: false, detailed: false)
            == "Opened com.apple.calculator · pressed 7")
        #expect(Self.copy(Self.calculator, detailed: false) == """
            Opened com.apple.calculator · pressed 7
            Checked open apps
            Checked Calcolatrice’s open windows
            Opened com.apple.calculator
            Pressed 7
            Tried to press Nonexistent
            """)
    }

    @Test("A debug copy drops sessions and timing, shortens scenes and trims the batch's end")
    func debugCopy() {
        let expected: [String] = [
            #"→ status {}"#,
            #"← status {"permissions":{"accessibility":true,"postEvent":true,"screenRecording":true}}"#,
            #"→ windows {"app":"Calcolatrice"}"#,
            #"← windows {"applications":[{"bundleID":"com.apple.calculator","name":"Calcolatrice","pid":13776,"#
                + #""windows":[{"id":27741,"title":"Calcolatrice"}]}]}"#,
            #"→ open_session {"app":"com.apple.calculator","window":"Calcolatrice"}"#,
            #"← open_session {"scene":"# + Self.shortScene + "}",
            #"→ batch {"steps":[{"operation":"act","target":"7","verb":"click"},"#
                + #"{"operation":"act","target":"Nonexistent","verb":"click"},"#
                + #"{"operation":"act","target":"8","verb":"click"}]}"#,
            #"← batch step 1 {"message":"clicked '7': reveals elements","status":"found_acted"}"#,
            #"← batch step 2 {"message":"no element 'Nonexistent' in Calcolatrice","status":"honest_miss"}"#,
            #"← batch {"attemptedSteps":2,"requested":3,"status":"stopped","verifiedSteps":1}"#,
        ]
        #expect(Self.copy(Self.calculator, isExpanded: false, detailed: true) == expected.joined(separator: "\n"))
    }

    @Test("A debug copy keeps errors, notes and records that are not JSON, and cuts a long record at 300")
    func debugCopyKeepsAndCuts() {
        let error = "← batch step 2 error: the session ended. Observe before any retry."
        let note  = "» Pressing 7 now."
        let plain = "list_branches"
        let long  = #"→ type_text {"session":"s1","target":"Notes","text":""#
            + String(repeating: "a", count: 400) + #""}"#
        let lines = Self.copy([error, note, plain, long], detailed: true).components(separatedBy: "\n")

        #expect(Array(lines.prefix(3)) == [error, note, plain])
        #expect(lines[3].count == ToolStep.copiedRecordLimit)
        #expect(lines[3].hasPrefix(#"→ type_text {"target":"Notes","text":"aaa"#))
        #expect(lines[3].hasSuffix("a…"))
    }

    @Test("A scene with no element count keeps only its first line")
    func sceneWithoutCount() {
        let line = #"← observe {"scene":"app: Notes\nnothing to list\n"}"#
        #expect(Self.copy([line], detailed: true) == #"← observe {"scene":"app: Notes"}"#)
    }
}
