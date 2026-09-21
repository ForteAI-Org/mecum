//
//  OutcomeVerificationTests.swift
//  AgentLab
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/09/2026.
//

import CoreGraphics
import PerceptionCore
import SeatCore
import SeatInput
import SeatSession
import Testing
@testable import SeatBroker

// MARK: Fixtures

private func blankImage() -> CGImage {
    CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
}

/// A scene with one background paragraph, which is what OCR reads and what a
/// repaint changes without anything having been dismissed.
private func scene(background: String) -> SceneSnapshot {
    SceneSnapshot(
        bundleID         : "com.example",
        appName          : "Example",
        windowTitle      : "Panel",
        viewportPixelSize: ViewportPixelSize(width: 20, height: 20),
        elements         : [
            PerceptionCore.SceneElement(id: "text|\(background)", kind: .text, label: background,
                                        bounds: NormalizedRect(x: 0.1, y: 0.8, width: 0.5, height: 0.1)),
            PerceptionCore.SceneElement(id: "control|cancel", kind: .control, label: "Annulla",
                                        bounds: NormalizedRect(x: 0.6, y: 0.6, width: 0.2, height: 0.1),
                                        role: "AXButton"),
        ]
    )
}

/// The sheet the Command was aimed at. The numbers are a fixture, never a
/// constant to implement: what matters is that the same identity is compared.
private let sheet = WindowIdentity(
    process: ProcessIdentity(processID: 37_751, serialNumberHigh: 1, serialNumberLow: 2),
    windowNumber: 47_626,
    ownerConnectionID: 5_072_459
)

private func element(_ index: Int, id: String, role: String?, state: String? = nil,
                     label: String = "field", value: String? = nil,
                     x: Double = 0.2, y: Double = 0.2)
    -> SceneObservation.Element {
    SceneObservation.Element(index: index, id: id, kind: "control", label: label, role: role, state: state, value: value,
                 bounds: CGRect(x: x, y: y, width: 0.2, height: 0.1))
}

// MARK: A scene that changed is not an effect that was verified

@Test func aBackgroundThatRepaintedWithTheDialogStillThereIsNotSuccess() {
    // The Cancel click's own surface still answers to its identity, so the
    // dismissal did not happen. Everything else about the frame moved.
    let result = OutcomeVerifier.verify(
        before: scene(background: "12 messaggi"), beforeImage: blankImage(),
        after: scene(background: "14 messaggi"), afterImage: blankImage(),
        targetID: "control|cancel",
        expected: .surfaceCloses(windowNumber: sheet.windowNumber),
        afterElements: [], surfaceIsGone: false
    )
    #expect(result.sceneChanged)
    #expect(result.outcome == .sceneChanged)
    #expect(!result.outcome.isVerified)
    #expect(result.summary.contains("the expected effect was not verified"))
}

@Test func aSceneThatDidNotMoveEitherIsOnlyPosted() {
    let result = OutcomeVerifier.verify(
        before: scene(background: "12 messaggi"), beforeImage: blankImage(),
        after: scene(background: "12 messaggi"), afterImage: blankImage(),
        targetID: "control|cancel",
        expected: .surfaceCloses(windowNumber: sheet.windowNumber),
        afterElements: [], surfaceIsGone: false
    )
    #expect(!result.sceneChanged)
    #expect(result.outcome == .posted)
}

@Test func theSameSurfaceBeingGoneIsTheVerifiedEffectHoweverLittleElseMoved() {
    let result = OutcomeVerifier.verify(
        before: scene(background: "12 messaggi"), beforeImage: blankImage(),
        after: scene(background: "12 messaggi"), afterImage: blankImage(),
        targetID: "control|cancel",
        expected: .surfaceCloses(windowNumber: sheet.windowNumber),
        afterElements: [], surfaceIsGone: true
    )
    #expect(result.outcome == .expectedEffectVerified)
}

// MARK: The predicate comes from the action and the surface

@Test func aClickOnAPlainControlIsHeldToTheClosureOfTheSurfaceItWasAimedAt() {
    #expect(ExpectedEffect.of(.click(element: 1), target: element(1, id: "b", role: "AXButton"),
                              surface: sheet) == .surfaceCloses(windowNumber: sheet.windowNumber))
    // Escape means dismiss; no other chord has an oracle in this lab.
    #expect(ExpectedEffect.of(.key(.escape), target: nil, surface: sheet)
            == .surfaceCloses(windowNumber: sheet.windowNumber))
    #expect(ExpectedEffect.of(.key(.a, modifiers: .command), target: nil, surface: sheet) == .unqualified)
    #expect(ExpectedEffect.of(.scroll(element: 1, deltaY: -3),
                              target: element(1, id: "b", role: "AXButton"), surface: sheet) == .unqualified)
}

@Test func aTypedFieldIsJudgedOnItsAccessibilityValueAndNeverOnPixelsAlone() {
    let field = element(1, id: "f", role: "AXTextField", label: "Name", value: "before")
    let expected = ExpectedEffect.of(.type(element: 1, text: "ciao"), target: field, surface: sheet)
    #expect(expected == .fieldReads(controlID: field.id, bounds: field.bounds, text: "ciao", beforeValue: "before"))

    // The same place, the value accessibility now answers with: verified.
    #expect(OutcomeVerifier.holds(expected, in: [element(1, id: "f", role: "AXTextField", label: "Name", value: "beforeciao")],
                                  surfaceIsGone: false))
    // The same place and the same text, read by OCR with no accessibility
    // role behind it: not an oracle, so not a verification.
    #expect(!OutcomeVerifier.holds(expected, in: [element(1, id: "f", role: nil, label: "ciao", value: "ciao")],
                                   surfaceIsGone: false))
    // Accessibility answers something else: the typing did not land.
    #expect(!OutcomeVerifier.holds(expected, in: [element(1, id: "f", role: "AXTextField", label: "Name", value: "before")],
                                   surfaceIsGone: false))
    // A matching label is presentation only. The old value already contains
    // the text, so no observed value transition means no verification.
    #expect(!OutcomeVerifier.holds(expected, in: [element(1, id: "f", role: "AXTextField", label: "ciao", value: "before")],
                                   surfaceIsGone: false))
}

@Test func aTypedValueMayBeInsertedAtAnyCaretPositionAndKeepsRawWhitespace() {
    let field = element(1, id: "field-id", role: "AXTextField", label: "Name", value: "ab cd")
    let mid = ExpectedEffect.of(.type(element: 1, text: "XYZ"), target: field, surface: sheet)
    #expect(OutcomeVerifier.holds(
        mid,
        in: [element(1, id: "field-id", role: "AXTextField", label: "Name", value: "abXYZ cd")],
        surfaceIsGone: false
    ))

    let raw = element(1, id: "field-id", role: "AXTextField", label: "Name", value: "left\n right")
    let spaces = ExpectedEffect.of(.type(element: 1, text: "  "), target: raw, surface: sheet)
    #expect(OutcomeVerifier.holds(
        spaces,
        in: [element(1, id: "field-id", role: "AXTextField", label: "Name", value: "left\n   right")],
        surfaceIsGone: false
    ))
}

@Test func aStatefulControlIsJudgedOnItsOwnStateChanging() {
    let box = element(1, id: "c", role: "AXCheckBox", state: "off", label: "Ricorda")
    let expected = ExpectedEffect.of(.click(element: 1), target: box, surface: sheet)
    #expect(expected == .stateFlips(bounds: box.bounds, from: "off"))
    #expect(OutcomeVerifier.holds(expected, in: [element(1, id: "c", role: "AXCheckBox", state: "on")],
                                  surfaceIsGone: false))
    #expect(!OutcomeVerifier.holds(expected, in: [element(1, id: "c", role: "AXCheckBox", state: "off")],
                                   surfaceIsGone: false))
}

@Test func anActionWithNoOracleNeverReachesVerified() {
    #expect(!OutcomeVerifier.holds(.unqualified, in: [element(1, id: "a", role: "AXButton")],
                                   surfaceIsGone: true))
}

// MARK: A refusal is never an executed action

@Test func aCommandRefusedBeforeItsFirstEventIsNotObservedAndNeverPosted() {
    #expect(OutcomeVerifier.refusedBeforePost.outcome == .notObserved)
    #expect(OutcomeVerifier.refusedBeforePost.outcome != .posted)
    #expect(!OutcomeVerifier.refusedBeforePost.sceneChanged)
    #expect(!OutcomeVerifier.refusedBeforePost.outcome.isVerified)
    #expect(!OutcomeVerifier.refusedBeforePost.outcome.isUncertain)
}

// MARK: The effect survives a reading that could not be taken

@Test @MainActor func aDismissalWhoseAfterFrameWasRefusedKeepsItsVerifiedEffect() {
    // Cancel went out, the panel's identity is gone from the window server,
    // and the focus coming back left no scene to perceive. The effect stands.
    let kept = OutcomeVerifier.interrupted(expected: .surfaceCloses(windowNumber: sheet.windowNumber),
                                           surfaceIsGone: true)
    #expect(kept.outcome == .expectedEffectVerified)
    #expect(AgentSession.confirmation(of: kept.outcome) == .observed)
    // And the plan does not go on to a second Cancel on stale indices.
    #expect(!AgentPlanner.continuesPlan(after: kept.outcome))
}

@Test @MainActor func anEffectNobodyCouldSettleIsUncertainAndIsNeverRepeated() {
    let uncertain = OutcomeVerifier.interrupted(expected: .surfaceCloses(windowNumber: sheet.windowNumber),
                                                surfaceIsGone: false)
    #expect(uncertain.outcome == .interruptedAfterPost)
    #expect(uncertain.outcome.isUncertain)
    // `unknown` is the kit's "never promoted, never replayed"; `absent` would
    // be the kit being told it may send the same Command again.
    #expect(AgentSession.confirmation(of: uncertain.outcome) == .unknown)
    #expect(!AgentPlanner.continuesPlan(after: uncertain.outcome))
    #expect(uncertain.summary.contains("do not repeat it"))
}

@Test @MainActor func onlyAPostedCommandThatChangedNothingLetsAPlanCarryOn() {
    #expect(AgentPlanner.continuesPlan(after: .posted))
    for outcome in [ActionOutcome.sceneChanged, .expectedEffectVerified, .interruptedAfterPost, .notObserved] {
        #expect(!AgentPlanner.continuesPlan(after: outcome))
    }
}

@Test @MainActor func theKitIsNeverToldAnEffectIsAbsentWhenNobodyLooked() {
    #expect(AgentSession.confirmation(of: .sceneChanged) == .observed)
    #expect(AgentSession.confirmation(of: .posted) == .absent)
    #expect(AgentSession.confirmation(of: .notObserved) == .absent)
}
