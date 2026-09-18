//
//  LabelTextTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

@testable import PerceptionCore
import Testing

@Suite("Label text")
struct LabelTextTests {

    @Test("normalize keeps alphanumerics only")
    func normalize() {
        #expect(LabelText.normalize("✓ 48000") == "48000")
        #expect(LabelText.normalize("New Track…") == "newtrack")
    }

    @Test("tokens, letters and nameworthiness")
    func tokensLettersNameworthy() {
        #expect(LabelText.tokens("#_all-team 2") == ["all", "team", "2"])
        #expect(LabelText.letters("Edit: GAME • v4") == "editgamev")
        #expect(LabelText.isNameworthy("H.264"))
        #expect(!LabelText.isNameworthy("•••"))
    }

    @Test("match score ranks exact over subset over overlap")
    func matchScore() {
        #expect(LabelText.matchScore(query: "New Track", against: "new track") == 3)
        #expect(LabelText.matchScore(query: "New Track", against: "Track New") == 2.5)
        #expect(LabelText.matchScore(query: "Track", against: "New Track") == 2)
        #expect(LabelText.matchScore(query: "New Audio Track", against: "New Video") == 1.0 / 3.0)
        #expect(LabelText.matchScore(query: "", against: "x") == 0)
    }

    @Test("core keys drop leading junk and punctuation")
    func coreKeys() {
        #expect(LabelText.coreKey("Ze Simone") == "simone")
        #expect(LabelText.coreKey("#_all-team") == "allteam")
        #expect(LabelText.coreKey("OK") == "ok")
    }

    @Test("stable labels are names, not measurements")
    func stableLabels() {
        #expect(LabelText.isStableLabel("Export"))
        #expect(!LabelText.isStableLabel("00:00:12:00"))
        #expect(!LabelText.isStableLabel("+17.6 db"))
        #expect(!LabelText.isStableLabel("-Od"))
        #expect(!LabelText.isStableLabel("x"))
    }

    @Test("display annotations peel repeatedly")
    func displayAnnotations() {
        #expect(LabelText.strippingDisplayAnnotations("Media File (row#3) [off]") == "Media File")
        #expect(LabelText.strippingDisplayAnnotations("Save (All)") == "Save")
        #expect(LabelText.strippingDisplayAnnotations("Plain") == "Plain")
    }
}
