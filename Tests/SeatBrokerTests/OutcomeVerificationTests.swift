//
//  OutcomeVerificationTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/09/2026.
//

import CoreGraphics
import EngineCore
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
    SceneObservation.Element(index: index, identity: id, kind: "control", label: label, role: role, state: state, value: value,
                 bounds: CGRect(x: x, y: y, width: 0.2, height: 0.1))
}

// MARK: The Engine's judgement, in this lab's vocabulary

@Test func aBackgroundThatRepaintedWithTheDialogStillThereIsNotSuccess() {
    // The Cancel click's own surface still answers to its identity, so the
    // dismissal did not happen. Everything else about the frame moved.
    let result = OutcomeVerifier.verify(
        before: scene(background: "12 messaggi"), beforeImage: blankImage(),
        after: scene(background: "14 messaggi"), afterImage: blankImage(),
        targetID: "control|cancel",
        oracle: .surfaceCloses(windowNumber: sheet.windowNumber),
        surfaceIsGone: false
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
        oracle: .surfaceCloses(windowNumber: sheet.windowNumber),
        surfaceIsGone: false
    )
    #expect(!result.sceneChanged)
    #expect(result.outcome == .posted)
}

@Test func theSameSurfaceBeingGoneIsTheVerifiedEffectHoweverLittleElseMoved() {
    let result = OutcomeVerifier.verify(
        before: scene(background: "12 messaggi"), beforeImage: blankImage(),
        after: scene(background: "12 messaggi"), afterImage: blankImage(),
        targetID: "control|cancel",
        oracle: .surfaceCloses(windowNumber: sheet.windowNumber),
        surfaceIsGone: true
    )
    #expect(result.outcome == .expectedEffectVerified)
}

@Test func anActionWithNoOracleNeverReachesVerifiedHoweverMuchTheSceneMoved() {
    // A scroll has no oracle here, and the Engine's two-scene rule alone is a
    // measurement: this lab's ceiling for it is `sceneChanged`.
    let result = OutcomeVerifier.verify(
        before: scene(background: "12 messaggi"), beforeImage: blankImage(),
        after: scene(background: "14 messaggi"), afterImage: blankImage(),
        targetID: "control|cancel", oracle: nil, surfaceIsGone: true
    )
    #expect(result.outcome == .sceneChanged)
    #expect(!result.outcome.isVerified)
}

// MARK: The oracle comes from the action and the surface

@Test func aClickOnAPlainControlIsHeldToTheClosureOfTheSurfaceItWasAimedAt() {
    #expect(ActOracle.of(.click(element: 1), target: element(1, id: "b", role: "AXButton"),
                         surface: sheet) == .surfaceCloses(windowNumber: sheet.windowNumber))
    // Escape means dismiss; no other chord has an oracle in this lab.
    #expect(ActOracle.of(.key(.escape), target: nil, surface: sheet)
            == .surfaceCloses(windowNumber: sheet.windowNumber))
    #expect(ActOracle.of(.key(.a, modifiers: .command), target: nil, surface: sheet) == nil)
    #expect(ActOracle.of(.scroll(element: 1, deltaY: -3),
                         target: element(1, id: "b", role: "AXButton"), surface: sheet) == nil)
}

@Test func aTypedFieldIsHeldToItsOwnAccessibilityValue() {
    let field = element(1, id: "f", role: "AXTextField", label: "Name", value: "before")
    #expect(ActOracle.of(.type(element: 1, text: "ciao"), target: field, surface: sheet)
            == .fieldReads(controlID: field.identity, bounds: field.bounds, text: "ciao", beforeValue: "before"))
    // Typing into something that is not a field has no value to read back.
    #expect(ActOracle.of(.type(element: 1, text: "ciao"),
                         target: element(1, id: "b", role: "AXButton"), surface: sheet) == nil)
}

@Test func aStatefulControlIsHeldToItsOwnState() {
    let box = element(1, id: "c", role: "AXCheckBox", state: "off", label: "Ricorda")
    #expect(ActOracle.of(.click(element: 1), target: box, surface: sheet)
            == .stateFlips(bounds: box.bounds, from: "off"))
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
    let kept = OutcomeVerifier.interrupted(oracle: .surfaceCloses(windowNumber: sheet.windowNumber),
                                           surfaceIsGone: true)
    #expect(kept.outcome == .expectedEffectVerified)
    #expect(AgentSession.confirmation(of: kept.outcome) == .observed)
    // And the plan does not go on to a second Cancel on stale indices.
    #expect(!AgentPlanner.continuesPlan(after: kept.outcome))
}

@Test @MainActor func anEffectNobodyCouldSettleIsUncertainAndIsNeverRepeated() {
    let uncertain = OutcomeVerifier.interrupted(oracle: .surfaceCloses(windowNumber: sheet.windowNumber),
                                                surfaceIsGone: false)
    #expect(uncertain.outcome == .interruptedAfterPost)
    #expect(uncertain.outcome.isUncertain)
    // `unknown` is the kit's "never promoted, never replayed"; `absent` would
    // be the kit being told it may send the same Command again.
    #expect(AgentSession.confirmation(of: uncertain.outcome) == .unknown)
    #expect(!AgentPlanner.continuesPlan(after: uncertain.outcome))
    #expect(uncertain.summary.contains("do not repeat it"))
    // An action with no oracle at all is uncertain for the same reason.
    #expect(OutcomeVerifier.interrupted(oracle: nil, surfaceIsGone: true).outcome == .interruptedAfterPost)
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
