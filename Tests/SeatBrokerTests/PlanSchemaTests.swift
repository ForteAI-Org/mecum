import CoreGraphics
import Foundation
import SeatCore
import Testing
@testable import SeatBroker

private func observation(count: Int) -> SceneObservation {
    let ctx = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let elements = (1...count).map {
        SceneElement(index: $0, identity: "e\($0)", kind: "control", label: "E\($0)", role: nil, state: nil,
                     bounds: CGRect(x: 0, y: 0, width: 0.1, height: 0.1))
    }
    return SceneObservation(image: ctx.makeImage()!, elements: elements, text: "", token: "t")
}

@Test func validatesTargetsAgainstTheScene() throws {
    let raw = RawPlan(status: "plan", reason: "go", steps: [
        .init(target: "2:click", text: nil, reason: "a"),
        .init(target: "1:type", text: "hello", reason: "b"),
        .init(target: "3:scroll", text: "-3", reason: "c"),
        .init(target: "key:return", text: nil, reason: "d"),
    ])
    let decision = try PlanSchema.decision(from: raw, observation: observation(count: 3))
    #expect(decision.status == .plan)
    #expect(decision.steps.map(\.action) == [.click(element: 2), .type(element: 1, text: "hello"),
                                             .scroll(element: 3, deltaY: -3), .key(.return)])
}

@Test func preservesAnExplicitBoundedClickCount() throws {
    let raw = RawPlan(status: "plan", reason: "open the item", steps: [
        .init(target: "2:click", text: nil, count: 2, reason: "double click"),
    ])
    let decision = try PlanSchema.decision(from: raw, observation: observation(count: 3))
    #expect(decision.steps.map(\.action) == [.click(element: 2, count: 2)])
}

@Test func refusesCountsOutsideTheInputContractOrOnAnotherVerb() {
    let scene = observation(count: 2)
    for count in [0, InputCommand.maximumClickCount + 1] {
        #expect(throws: PlanValidationError.self) {
            try PlanSchema.decision(from: RawPlan(status: "plan", reason: "", steps: [
                .init(target: "1:click", text: nil, count: count, reason: ""),
            ]), observation: scene)
        }
    }
    #expect(throws: PlanValidationError.self) {
        try PlanSchema.decision(from: RawPlan(status: "plan", reason: "", steps: [
            .init(target: "1:type", text: "hello", count: 2, reason: ""),
        ]), observation: scene)
    }
    #expect(throws: PlanValidationError.self) {
        try PlanSchema.decision(from: RawPlan(status: "plan", reason: "", steps: [
            .init(target: "key:cmd+o", text: nil, count: 3, reason: ""),
        ]), observation: scene)
    }
}

/// The schema requires "count" on every step, so a structured-output mode fills
/// it in on steps that have nothing to click. One click is what those three
/// values all mean, and refusing them refused every plan with a key in it.
@Test(arguments: [nil, 0, 1] as [Int?])
func readsAnEmptyCountOnANonClickStepAsNoCount(count: Int?) throws {
    let raw = RawPlan(status: "plan", reason: "open the panel", steps: [
        .init(target: "key:cmd+o", text: nil, count: count, reason: "a"),
        .init(target: "1:type", text: "hi", count: count, reason: "b"),
        .init(target: "2:scroll", text: "-3", count: count, reason: "c"),
    ])
    let decision = try PlanSchema.decision(from: raw, observation: observation(count: 2))
    #expect(decision.steps.map(\.action) == [.key(.o, modifiers: .command), .type(element: 1, text: "hi"),
                                            .scroll(element: 2, deltaY: -3)])
}

@Test func acceptsShortcutTargetsAndRefusesTheOnesThatEndTheRun() throws {
    let scene = observation(count: 1)
    let plan = RawPlan(status: "plan", reason: "copy", steps: [.init(target: "key:cmd+c", text: nil, reason: "a")])
    #expect(try PlanSchema.decision(from: plan, observation: scene).steps.map(\.action)
            == [.key(.c, modifiers: .command)])
    for chord in ["key:cmd+q", "key:cmd+w"] {
        #expect(throws: PlanValidationError.self) {
            try PlanSchema.decision(from: RawPlan(status: "plan", reason: "", steps: [.init(target: chord, text: nil, reason: "")]),
                                    observation: scene)
        }
    }
}

@Test func rejectsUnknownIndexMissingTextAndProse() {
    let scene = observation(count: 2)
    #expect(throws: PlanValidationError.self) {
        try PlanSchema.decision(from: RawPlan(status: "plan", reason: "", steps: [.init(target: "9:click", text: nil, reason: "")]), observation: scene)
    }
    #expect(throws: PlanValidationError.self) {
        try PlanSchema.decision(from: RawPlan(status: "plan", reason: "", steps: [.init(target: "1:type", text: nil, reason: "")]), observation: scene)
    }
    #expect(throws: PlanValidationError.self) {
        try PlanSchema.decision(from: RawPlan(status: "plan", reason: "", steps: [.init(target: "1:click or 2:click", text: nil, reason: "")]), observation: scene)
    }
}

@Test func acceptsLabelOrBareIndexAsTarget() throws {
    let ctx = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scene = SceneObservation(image: ctx.makeImage()!, elements: [
        SceneElement(index: 1, identity: "a", kind: "text", label: "Ron", role: nil, state: nil, bounds: .init(x: 0, y: 0, width: 0.1, height: 0.1)),
        SceneElement(index: 2, identity: "b", kind: "text", label: "Andrea 15:22", role: nil, state: nil, bounds: .init(x: 0, y: 0.5, width: 0.1, height: 0.1)),
    ], text: "", token: "t")
    let raw = RawPlan(status: "plan", reason: "", steps: [
        .init(target: "Andrea 15:22", text: nil, reason: ""),
        .init(target: "ron", text: "hello", reason: ""),
        .init(target: "[2]", text: nil, reason: ""),
        .init(target: "[1]:click", text: nil, reason: ""),
        .init(target: "# 2 : type", text: "x", reason: ""),
    ])
    let decision = try PlanSchema.decision(from: raw, observation: scene)
    #expect(decision.steps.map(\.action) == [.click(element: 2), .type(element: 1, text: "hello"), .click(element: 2),
                                             .click(element: 1), .type(element: 2, text: "x")])
}

@Test func stepsWinOverAContradictoryStatus() throws {
    let raw = RawPlan(status: "completed", reason: "", steps: [.init(target: "1:click", text: nil, reason: "")])
    let decision = try PlanSchema.decision(from: raw, observation: observation(count: 2))
    #expect(decision.status == .plan)
    #expect(decision.steps.count == 1)
}

@Test func everySchemaFlavorSerializes() throws {
    for flavor in [PlanSchema.Flavor.full, .anthropic, .gemini] {
        let data = try PlanSchema.json(maximumSteps: 4, flavor: flavor)
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((root["required"] as? [String]) == ["status", "reason", "steps", "application"])
        #expect((root["additionalProperties"] as? Bool) == (flavor == .gemini ? nil : false))
    }
}

@Test func everySchemaFlavorOffersOpenAndItsNullableApplication() throws {
    for flavor in [PlanSchema.Flavor.full, .anthropic, .gemini] {
        let data = try PlanSchema.json(maximumSteps: 4, flavor: flavor)
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let properties = root["properties"] as! [String: Any]
        #expect((properties["status"] as? [String: Any])?["enum"] as? [String]
                == ["plan", "completed", "blocked", "open"])
        // Each provider spells "a string or nothing" its own way, and a name
        // carries no length limit the way a typed text does.
        let application = properties["application"] as! [String: Any]
        switch flavor {
        case .full:
            #expect((application["type"] as? [String]) == ["string", "null"])
            #expect(application["maxLength"] == nil)
        case .anthropic:
            #expect((application["anyOf"] as? [[String: String]])?.count == 2)
        case .gemini:
            #expect((application["type"] as? String) == "string")
            #expect((application["nullable"] as? Bool) == true)
        }
    }
}

@Test func parsesAnOpenDecisionAndDropsWhatItPlannedForTheOldScene() throws {
    let scene = observation(count: 2)
    let raw = RawPlan(status: "open", reason: "the goal is about photos", steps: [], application: " Photos ")
    let decision = try PlanSchema.decision(from: raw, observation: scene)
    #expect(decision.status == .open)
    #expect(decision.application == "Photos")
    #expect(decision.steps.isEmpty)

    // Steps win over a contradictory status everywhere else, and never here: an
    // index out of range belongs to the scene the open replaces.
    let alsoPlanned = RawPlan(status: "open", reason: "", steps: [.init(target: "9:click", text: nil, reason: "")],
                              application: "Photos")
    let opening = try PlanSchema.decision(from: alsoPlanned, observation: scene)
    #expect(opening.status == .open)
    #expect(opening.steps.isEmpty)
}

@Test func refusesAnOpenThatNamesNoApplication() throws {
    let scene = observation(count: 2)
    for name in [nil, "", "   "] as [String?] {
        #expect(throws: PlanValidationError.self) {
            try PlanSchema.decision(from: RawPlan(status: "open", reason: "", steps: [], application: name),
                                    observation: scene)
        }
    }
    // A provider that leaves the key out of its answer decodes all the same,
    // and is refused by the same rule rather than by the decoder.
    let raw = try JSONDecoder().decode(RawPlan.self, from: Data(#"{"status":"open","reason":"r","steps":[]}"#.utf8))
    #expect(raw.application == nil)
    #expect(throws: PlanValidationError.self) {
        try PlanSchema.decision(from: raw, observation: scene)
    }
    // Every other status carries no application, whatever the model sent.
    let planned = RawPlan(status: "plan", reason: "", steps: [.init(target: "1:click", text: nil, reason: "")],
                          application: "Photos")
    #expect(try PlanSchema.decision(from: planned, observation: scene).application == nil)
}

@Test func decodesCodexEventStream() throws {
    let plan = #"{"status":"plan","reason":"r","steps":[{"target":"1:click","text":null,"reason":"s"}]}"#
    let lines = [
        #"{"type":"turn.started"}"#,
        #"{"type":"item.completed","item":{"type":"reasoning","text":"..."}}"#,
        #"{"type":"item.completed","item":{"type":"agent_message","text":\#(String(reflecting: plan))}}"#,
        #"{"type":"turn.completed"}"#,
    ].joined(separator: "\n")
    let data = try CodexCLIClient.decodeStructuredOutput(output: Data(lines.utf8), exitStatus: 0)
    let raw = try JSONDecoder().decode(RawPlan.self, from: data)
    #expect(raw.steps.first?.target == "1:click")
}

@Test func refusesToolUseInCodexStream() {
    let lines = [
        #"{"type":"turn.started"}"#,
        #"{"type":"item.completed","item":{"type":"command_execution","command":"ls"}}"#,
        #"{"type":"turn.completed"}"#,
    ].joined(separator: "\n")
    #expect(throws: CodexClientError.self) {
        try CodexCLIClient.decodeStructuredOutput(output: Data(lines.utf8), exitStatus: 0)
    }
}
