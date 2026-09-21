//
//  ActOracleTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics
@testable import EngineCore
import PerceptionCore
import Testing

/// The reading that settles what two scenes cannot: the window server's list and the accessibility
/// value or state of the control acted on. Ported from the lab's own verifier, where a repainted
/// background used to be told apart from a dismissed sheet by the picture alone.
@Suite("Act oracles")
struct ActOracleTests {

    /// A fixture, never a constant to implement: what matters is that the same identity is asked.
    private static let windowNumber = 47_626

    private func scene(_ elements: [SceneElement], title: String = "Panel") -> SceneSnapshot {
        SceneSnapshot(bundleID: "com.example", appName: "Example", windowTitle: title,
                      viewportPixelSize: ViewportPixelSize(width: 20, height: 20), elements: elements)
    }

    /// The background paragraph OCR reads, and what a repaint changes without anything having closed.
    private func text(_ label: String) -> SceneElement {
        SceneElement(id: "text|\(label)", kind: .text, label: label,
                     bounds: NormalizedRect(x: 0.1, y: 0.8, width: 0.5, height: 0.1))
    }

    private let cancel = SceneElement(id: "control|cancel", kind: .control, label: "Annulla",
                                      bounds: NormalizedRect(x: 0.6, y: 0.6, width: 0.2, height: 0.1),
                                      role: "AXButton")

    private func control(id: String, role: String?, state: ControlState? = nil,
                         label: String = "field", value: String? = nil) -> SceneElement {
        SceneElement(id: id, kind: .control, label: label,
                     bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.2, height: 0.1),
                     role: role, state: state, value: value)
    }

    private let controlBounds = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.1)

    private func evidence(_ after: SceneSnapshot?, listed: Bool) -> OracleEvidence {
        OracleEvidence(after: after, surfaceIsListed: listed)
    }

    // MARK: A scene that changed is not an effect that was verified

    @Test("a background that repainted with the surface still listed is not success")
    func repaintIsNotADismissal() {
        let before = scene([text("12 messaggi"), cancel]), after = scene([text("14 messaggi"), cancel])
        let verdict = ActVerification.verdict(before: before, after: after, targetID: cancel.id)
        let outcome = ActVerification.outcome(
            for: verdict, label: "Annulla", after: after,
            oracle: .surfaceCloses(windowNumber: Self.windowNumber), evidence: evidence(after, listed: true)
        )
        #expect(outcome.kind == .actedUnverified)
        #expect(!outcome.isSuccess)
        #expect(outcome.message.contains("still lists window \(Self.windowNumber)"))
    }

    @Test("a scene that did not move is a ghost the oracle does not rescue")
    func ghostWithATheSurfaceStillListed() {
        let before = scene([text("12 messaggi"), cancel])
        let verdict = ActVerification.verdict(before: before, after: before, targetID: cancel.id)
        #expect(verdict == .ghost)
        let outcome = ActVerification.outcome(
            for: verdict, label: "Annulla", after: before,
            oracle: .surfaceCloses(windowNumber: Self.windowNumber), evidence: evidence(before, listed: true)
        )
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.message.contains("did NOT change"))
        #expect(outcome.message.contains("still lists window \(Self.windowNumber)"))
    }

    @Test("the surface being gone is the verified effect however little else moved")
    func theClosureOracleDecidesOnItsOwn() {
        let before = scene([text("12 messaggi"), cancel])
        let verdict = ActVerification.verdict(before: before, after: before, targetID: cancel.id)
        let outcome = ActVerification.outcome(
            for: verdict, label: "Annulla", after: before,
            oracle: .surfaceCloses(windowNumber: Self.windowNumber), evidence: evidence(before, listed: false)
        )
        #expect(outcome.kind == .foundActed)
        #expect(outcome.isSuccess)
        #expect(outcome.message.contains("no longer lists window \(Self.windowNumber)"))
    }

    @Test("a structural effect the oracle does not cover is not the gesture's proof")
    func aLandedEffectIsDemotedByAContradictedOracle() {
        let before = scene([control(id: "sw", role: "AXCheckBox", state: .off, label: "Ricorda")])
        let after  = scene([control(id: "sw", role: "AXCheckBox", state: .on, label: "Ricorda")])
        let verdict = ActVerification.verdict(before: before, after: after, targetID: "sw")
        #expect(verdict == .landed(.stateFlip(from: .off, to: .on), matchesExpectation: true))
        let outcome = ActVerification.outcome(
            for: verdict, label: "Ricorda", after: after,
            oracle: .surfaceCloses(windowNumber: Self.windowNumber), evidence: evidence(after, listed: true)
        )
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.message.contains("re-perceive and re-decide"))
    }

    @Test("with no oracle the two-scene rule is exactly what it was")
    func noOracleChangesNothing() {
        let before = scene([text("12 messaggi"), cancel]), after = scene([text("14 messaggi"), cancel])
        for verdict in [ActVerification.verdict(before: before, after: before, targetID: cancel.id),
                        ActVerification.verdict(before: before, after: after, targetID: cancel.id)] {
            let plain  = ActVerification.outcome(for: verdict, label: "Annulla", after: after)
            let asked  = ActVerification.outcome(for: verdict, label: "Annulla", after: after,
                                                 oracle: nil, evidence: evidence(after, listed: false))
            #expect(asked == plain)
        }
    }

    // MARK: The accessibility oracles

    @Test("a typed field is judged on its accessibility value and never on pixels alone")
    func typedFieldReadsItsValue() {
        let oracle = ActOracle.fieldReads(controlID: "f", bounds: controlBounds, text: "ciao",
                                          beforeValue: "before")
        // The same place, the value accessibility now answers with: verified.
        #expect(oracle.holds(given: evidence(
            scene([control(id: "f", role: "AXTextField", label: "Name", value: "beforeciao")]), listed: true)))
        // The same place and the same text, read by OCR with no accessibility role behind it.
        #expect(!oracle.holds(given: evidence(
            scene([control(id: "f", role: nil, label: "ciao", value: "ciao")]), listed: true)))
        // Accessibility answers something else: the typing did not land.
        #expect(!oracle.holds(given: evidence(
            scene([control(id: "f", role: "AXTextField", label: "Name", value: "before")]), listed: true)))
        // A matching label is presentation only, and the old value already contains the text.
        #expect(!oracle.holds(given: evidence(
            scene([control(id: "f", role: "AXTextField", label: "ciao", value: "before")]), listed: true)))
        // No scene at all: the value oracle has nothing to read and never guesses.
        #expect(!oracle.holds(given: evidence(nil, listed: false)))
    }

    @Test("a typed value may be inserted at any caret position and keeps raw whitespace")
    func typedValueTransitionIsExact() {
        let mid = ActOracle.fieldReads(controlID: "field-id", bounds: controlBounds, text: "XYZ",
                                       beforeValue: "ab cd")
        #expect(mid.holds(given: evidence(
            scene([control(id: "field-id", role: "AXTextField", label: "Name", value: "abXYZ cd")]), listed: true)))
        #expect(!mid.holds(given: evidence(
            scene([control(id: "field-id", role: "AXTextField", label: "Name", value: "abXY cd")]), listed: true)))

        let spaces = ActOracle.fieldReads(controlID: "field-id", bounds: controlBounds, text: "  ",
                                          beforeValue: "left\n right")
        #expect(spaces.holds(given: evidence(
            scene([control(id: "field-id", role: "AXTextField", label: "Name", value: "left\n   right")]),
            listed: true)))
    }

    @Test("a stateful control is judged on its own state changing")
    func stateFlipReadsTheControl() {
        let oracle = ActOracle.stateFlips(bounds: controlBounds, from: "off")
        #expect(oracle.holds(given: evidence(
            scene([control(id: "c", role: "AXCheckBox", state: .on, label: "Ricorda")]), listed: true)))
        #expect(!oracle.holds(given: evidence(
            scene([control(id: "c", role: "AXCheckBox", state: .off, label: "Ricorda")]), listed: true)))
        // No accessibility role at that place: a recognized guess is not an oracle.
        #expect(!oracle.holds(given: evidence(
            scene([control(id: "c", role: nil, state: .on, label: "Ricorda")]), listed: true)))
    }

    // MARK: The effect survives a reading that could not be taken

    @Test("a dismissal whose after-scene could not be read keeps its verified effect")
    func interruptedKeepsAHoldingOracle() {
        let kept = ActVerification.interrupted(label: "Annulla",
                                               oracle: .surfaceCloses(windowNumber: Self.windowNumber),
                                               evidence: evidence(nil, listed: false))
        #expect(kept.kind == .foundActed)
        #expect(kept.message.contains("no longer lists window \(Self.windowNumber)"))
    }

    @Test("an effect nobody could settle is uncertain and is never repeated")
    func interruptedWithoutAnOracleThatHolds() {
        let uncertain = ActVerification.interrupted(label: "Annulla",
                                                    oracle: .surfaceCloses(windowNumber: Self.windowNumber),
                                                    evidence: evidence(nil, listed: true))
        #expect(uncertain.kind == .actedUnverified)
        #expect(uncertain.message.contains("do not repeat it"))

        let unqualified = ActVerification.interrupted(label: "Annulla", oracle: nil,
                                                      evidence: evidence(nil, listed: false))
        #expect(unqualified.kind == .actedUnverified)
        #expect(!unqualified.isSuccess)
    }
}
