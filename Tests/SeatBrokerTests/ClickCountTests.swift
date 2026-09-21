//
//  ClickCountTests.swift
//  AgentLab
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics
import Foundation
import Testing
@testable import SeatBroker

private func oneElementScene() -> SceneObservation {
    let ctx = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let element = SceneElement(index: 12, identity: "e12", kind: "text", label: "prova_file", role: nil,
                               state: nil, bounds: CGRect(x: 0, y: 0, width: 0.1, height: 0.1))
    return SceneObservation(image: ctx.makeImage()!, elements: [element], text: "scene body", token: "t")
}

@Test func bothPromptsSayHowAFilePanelIsOpenedAndForbidRepeatingAVerifiedStep() {
    for compact in [false, true] {
        let prompt = PlannerPrompt.build(goal: "send a file", app: "Slack", windowTitle: "Open",
                                         observation: oneElementScene(), history: [],
                                         applications: "Slack", maximumSteps: 4, compact: compact)
        #expect(prompt.contains("a single click only selects the row"))
        #expect(prompt.contains("\"count\": 2"))
        #expect(prompt.contains("\"key:return\""))
        #expect(prompt.lowercased().contains("open or choose"))
        #expect(prompt.contains("Never send again the step the previous verified history line already names"))
    }
}

@Test @MainActor func theHistoryLineOfADoubleClickCarriesItsCount() {
    let scene = oneElementScene()
    let report = ActionReport(action: .click(element: 12, count: 2), targetLabel: "prova_file",
                              before: scene, after: scene,
                              verification: VerificationResult(outcome: .sceneChanged, sceneChanged: true,
                                                               effect: nil, pixelDifference: 0.0005),
                              eventCount: 4, duration: .milliseconds(120))
    let line = AgentPlanner.historyLine(step: 3, report: report)
    #expect(line.contains("click [12] x2 prova_file"))

    let single = ActionReport(action: .click(element: 12), targetLabel: "prova_file", before: scene, after: scene,
                              verification: VerificationResult(outcome: .sceneChanged, sceneChanged: true,
                                                               effect: nil, pixelDifference: 0.0005),
                              eventCount: 2, duration: .milliseconds(120))
    #expect(!AgentPlanner.historyLine(step: 4, report: single).contains("[12] x"))
}

@Test func aStepRecordKeepsItsClickCountAndAnOlderOneReadsBackAsASingleClick() throws {
    let step = RunStepRecord(index: 1, verb: "click", element: 12, targetLabel: "prova_file",
                             outcome: .sceneChanged, sceneChanged: true, effect: nil, pixelDifference: 0.0005,
                             eventCount: 4, milliseconds: 120, count: 2)
    let round = try JSONDecoder().decode(RunStepRecord.self, from: JSONEncoder().encode(step))
    #expect(round == step)
    #expect(round.count == 2)

    let older = """
        {"index":1,"verb":"click","element":12,"targetLabel":"prova_file","outcome":"sceneChanged",
         "sceneChanged":true,"eventCount":2,"milliseconds":120}
        """
    #expect(try JSONDecoder().decode(RunStepRecord.self, from: Data(older.utf8)).count == 1)
}
