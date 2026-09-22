//
//  EmptySeatTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 17/09/2026.
//

import CoreGraphics
import Foundation
import Testing
@testable import SeatBroker

private func scene(_ count: Int) -> SceneObservation {
    let ctx = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let elements = (0..<count).map {
        SceneElement(index: $0 + 1, identity: "e\($0)", kind: "control", label: "E\($0)", role: nil, state: nil,
                     bounds: CGRect(x: 0, y: 0, width: 0.1, height: 0.1))
    }
    return SceneObservation(image: ctx.makeImage()!, elements: elements, text: "scene body", token: "t")
}

@Test @MainActor func aSessionStartsHoldingNothingAndRefusesToActUntilSomethingIsAdopted() async {
    let session = SeatBroker().openSession()
    #expect(session.isOpen)
    #expect(!session.isUsingApp)
    #expect(session.app == nil)
    #expect(session.target == nil)
    // A degenerate frame would collapse the live monitor, so it is the empty
    // rectangle and the view decides what to draw for it.
    #expect(session.windowFrame == .zero)

    await #expect(throws: SeatBrokerError.self) { try await session.observe() }
    await #expect(throws: SeatBrokerError.self) { try await session.execute(.click(element: 1)) }
}

@Test func theEmptySeatPromptAsksForAnOpenAndOffersNoSceneToActOn() {
    for compact in [false, true] {
        let prompt = PlannerPrompt.build(goal: "reply to Ron", app: nil, windowTitle: nil, observation: nil,
                                         history: [], applications: "Messages, Safari", maximumSteps: 4,
                                         compact: compact)
        #expect(prompt.contains("There is no application on the seat and no scene"))
        #expect(prompt.contains("The only answer accepted now is status=\"open\""))
        #expect(prompt.contains("Messages, Safari"))
        // No application line and no scene block: naming either would describe
        // something that is not there.
        #expect(!prompt.contains("Application: "))
        #expect(!prompt.contains("App: "))
        #expect(!prompt.contains("Scene ("))
    }
}

@Test func aSceneIsStillDescribedTheWayItWasWhenOneIsAdopted() {
    let prompt = PlannerPrompt.build(goal: "reply to Ron", app: "Messages", windowTitle: "Ron",
                                     observation: scene(2), history: ["step 1: click Ron → changed"],
                                     applications: "Messages", maximumSteps: 4)
    #expect(prompt.contains("Application: Messages"))
    #expect(prompt.contains("Window title: Ron"))
    #expect(prompt.contains("Scene (2 elements):"))
    #expect(prompt.contains("scene body"))
    #expect(!prompt.contains("There is no application on the seat"))
}

@Test func withNoSceneAnOpenIsAcceptedAndEveryIndexedStepIsRefused() throws {
    let open = RawPlan(status: "open", reason: "the goal is about Messages", steps: [], application: "Messages")
    let decision = try PlanSchema.decision(from: open, observation: nil)
    #expect(decision.status == .open)
    #expect(decision.application == "Messages")

    // There is no scene, so every index names nothing: the count in the
    // rejection is nought, which is what the model is told to correct.
    #expect(throws: PlanValidationError.self) {
        try PlanSchema.decision(from: RawPlan(status: "plan", reason: "", steps: [
            .init(target: "1:click", text: nil, reason: "")
        ]), observation: nil)
    }
    #expect(throws: PlanValidationError.self) {
        try PlanSchema.decision(from: RawPlan(status: "plan", reason: "", steps: [
            .init(target: "Send", text: nil, reason: "")
        ]), observation: nil)
    }
}
