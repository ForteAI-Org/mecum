//
//  BrainApplicationContractTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

/// The application contract on its own: a call normalized once into the inputs the algorithm reads,
/// the versioned arguments it is stored as and read back from, the refusals of both ways, and the
/// exact comparison that tells a retry from a conflict.
@Suite("The brain application contract: normalized inputs, versioned arguments, exact comparison")
struct BrainApplicationContractTests {

    private let t0 = Fixtures.t0
    private let sample = CaptureSampleKey(eventID: "e1", phase: .after)

    private func detection(_ label: String, x: Double = 0.5, y: Double = 0.1, kind: ElementKind = .control,
                           state: ControlState? = nil) -> BrainDetection {
        BrainDetection(kind: kind, label: label, bounds: Fixtures.rect(x, y), state: state)
    }

    private func observe(_ detections: [BrainDetection], window: String? = "inbox", at: Date? = nil) throws -> BrainApplicationCommand {
        try .observe(detections: detections, window: window, bundleID: "test.app", sample: sample, requestedAt: at ?? t0)
    }

    @Test("an observed scene keeps every element as the brain reads it, pixel-only and unlabeled included, with BrainMemory's window family")
    func observeNormalizesOnce() throws {
        let scene = SceneSnapshot(
            bundleID: "test.app", appName: "Test", windowTitle: "Inbox (3)",
            viewportPixelSize: ViewportPixelSize(width: 1000, height: 800),
            elements: [
                SceneElement(id: "icon", kind: .icon, label: "(unlabeled)", bounds: Fixtures.rect(0.1, 0.1), isUnlabeled: true),
                SceneElement(id: "send", kind: .control, label: "Send", bounds: Fixtures.rect(0.3, 0.3), role: "AXButton", state: .off),
                SceneElement(id: "text", kind: .text, label: "Hello", bounds: Fixtures.rect(0.2, 0.5)),
            ]
        )
        let command = try BrainApplicationCommand.observe(scene, sample: sample, requestedAt: Date(timeIntervalSince1970: 1_700_000_000.1236))
        guard case .observe(let window, let detections) = command.input else {
            Issue.record("expected an observation")
            return
        }
        #expect(window == "inbox")
        #expect(detections == scene.elements.map(BrainDetection.init))
        #expect(detections.map(\.label) == ["", "Send", "Hello"])
        #expect(command.requestedAtMS == 1_700_000_000_124, "the requested instant is canonical once, at the boundary")
        #expect(command.key == .observe(sample) && command.bundleID == "test.app")
        let untitled = try BrainApplicationCommand.observe(
            SceneSnapshot(bundleID: "test.app", appName: "Test", windowTitle: "123 – 456",
                          viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: []),
            sample: sample, requestedAt: t0)
        guard case .observe(nil, let none) = untitled.input else {
            Issue.record("an empty family is no scope")
            return
        }
        #expect(none.isEmpty)
    }

    @Test("a record keeps the verb, the target's detection and the effect as typed columns, or no effect at all; a naming keeps the key and the name as given")
    func recordAndNameNormalize() throws {
        let element = SceneElement(id: "x", kind: .control, label: "(unlabeled)", bounds: Fixtures.rect(0.2, 0.2), state: .on, isUnlabeled: true)
        let record = try BrainApplicationCommand.record(
            ActionRecord(bundleID: "test.app", element: element, verb: .rightClick, effect: .menuOpened(labels: ["Copy", "Paste"]),
                         windowTitleAfter: "ignored"),
            eventID: "e2", requestedAt: t0)
        guard case .record(.rightClick, let target, let effect?) = record.input else {
            Issue.record("expected a record with an effect")
            return
        }
        #expect(target == BrainDetection(element) && target.label.isEmpty && target.state == .on)
        #expect(effect.kind == "menuOpened" && effect.items == ["Copy", "Paste"])
        let silent = try BrainApplicationCommand.record(
            ActionRecord(bundleID: "test.app", element: element, verb: .click, effect: nil, windowTitleAfter: nil), eventID: "e3", requestedAt: t0)
        guard case .record(.click, _, nil) = silent.input else {
            Issue.record("expected a record without effect")
            return
        }
        let name = try BrainApplicationCommand.setName("  Send  ", anchorKey: "no-such-anchor", in: "test.app", eventID: "e4", requestedAt: t0)
        guard case .setName("no-such-anchor", "  Send  ") = name.input else {
            Issue.record("the name is kept as given; the algorithm trims it")
            return
        }
        #expect(name.key == .setName(eventID: "e4") && name.key.sample == nil)
    }

    @Test("a command no store should apply is refused before any transaction, and the effects and clocks keep their typed errors")
    func invalidCommands() throws {
        #expect(throws: BrainApplicationError.invalidCommand(.nonFiniteBounds(argument: "detection_y", position: 1))) {
            _ = try observe([detection("A"), BrainDetection(kind: .control, label: "B", bounds: Fixtures.rect(0.1, .nan))])
        }
        #expect(throws: BrainApplicationError.invalidCommand(.emptyBundleID)) {
            _ = try BrainApplicationCommand.observe(detections: [], window: nil, bundleID: "", sample: sample, requestedAt: t0)
        }
        #expect(throws: BrainApplicationError.invalidCommand(.emptyEventID)) {
            _ = try BrainApplicationCommand.setName("x", anchorKey: "k", in: "test.app", eventID: "", requestedAt: t0)
        }
        #expect(throws: BrainApplicationError.invalidCommand(.negativeOrdinal)) {
            _ = try BrainApplicationCommand.observe(detections: [], window: nil, bundleID: "test.app",
                                                    sample: CaptureSampleKey(eventID: "e1", phase: .after, ordinal: -1), requestedAt: t0)
        }
        #expect(throws: BrainApplicationError.invalidCommand(.inputDoesNotMatchOperation)) {
            _ = try BrainApplicationCommand(key: .record(eventID: "e1"), bundleID: "test.app", requestedAtMS: 0,
                                            input: .setName(anchorKey: "k", name: "n"))
        }
        #expect(throws: BrainProjectionError.clock(.notFinite)) { _ = try observe([], at: Date(timeIntervalSince1970: .nan)) }
        #expect(throws: BrainProjectionError.clock(.dateOutOfRange(seconds: 1e16))) { _ = try observe([], at: Date(timeIntervalSince1970: 1e16)) }
        #expect(throws: BrainProjectionError.unrepresentableEffect("menuOpened:Open|", .notCanonical)) {
            _ = try BrainApplicationCommand.record(
                ActionRecord(bundleID: "test.app", element: SceneElement(id: "x", kind: .control, label: "X", bounds: Fixtures.rect(0.1, 0.1)),
                             verb: .click, effect: .menuOpened(labels: ["Open", ""]), windowTitleAfter: nil),
                eventID: "e1", requestedAt: t0)
        }
    }

    @Test("the arguments follow the versioned contract: every name admitted, typed, at its position, and they rebuild the very command")
    func argumentsRoundTrip() throws {
        let observation = try observe([detection("Send", state: .on), detection("", kind: .icon), detection("Mute", y: 0.3)])
        #expect(observation.arguments.map(\.name).prefix(3) == ["detection_count", "window", "detection_kind"])
        #expect(observation.arguments.filter { $0.name == "detection_state" }.map(\.position) == [0])
        #expect(observation.arguments.filter { $0.name == "detection_label" }.map(\.value) == [.text("Send"), .text(""), .text("Mute")])
        let record = try BrainApplicationCommand(
            key: .record(eventID: "e2"), bundleID: "test.app", requestedAtMS: 5,
            input: .record(verb: .setToggle, target: detection("Wi-Fi", state: .off),
                           effect: try TransitionEffectRecord(effect: "elementsAppeared:Queue|Export")))
        let named = try BrainApplicationCommand.setName("", anchorKey: "k", in: "test.app", eventID: "e3", requestedAt: t0)
        for command in [observation, record, named, try observe([], window: nil)] {
            let rebuilt = try BrainApplicationCommand(key: command.key, bundleID: command.bundleID, requestedAtMS: command.requestedAtMS,
                                                      arguments: command.arguments, applicationID: 1)
            #expect(rebuilt.hasSameInput(as: command))
            #expect(rebuilt.arguments == command.arguments)
            let specs = Set(BrainApplicationContract.arguments(of: command.key.operation).map(\.name))
            #expect(command.arguments.allSatisfy { specs.contains($0.name) })
        }
        #expect(try observe([], window: nil).arguments == [BrainArgument(name: "detection_count", position: 0, value: .integer(0))],
                "an empty ingest still has its count: absence of input is not absence of the list")
    }

    @Test("stored arguments the contract does not admit are refused on the way out by name, kind, position or code")
    func malformedArgumentsRefused() throws {
        let base = try observe([detection("Send", state: .on), detection("Mute", y: 0.3)])
        func rebuild(_ arguments: [BrainArgument], key: BrainApplicationKey? = nil) throws -> BrainApplicationCommand {
            try BrainApplicationCommand(key: key ?? base.key, bundleID: "test.app", requestedAtMS: base.requestedAtMS,
                                        arguments: arguments, applicationID: 7)
        }
        func refusal(_ malformation: BrainApplicationError.Malformation) -> BrainApplicationError {
            .malformedApplication(applicationID: 7, malformation: malformation)
        }
        let args = base.arguments
        #expect(throws: refusal(.forbiddenArgument("verb"))) { _ = try rebuild(args + [BrainArgument(name: "verb", position: 0, value: .text("click"))]) }
        #expect(throws: refusal(.argumentKindMismatch("detection_x"))) {
            _ = try rebuild(args.map { $0.name == "detection_x" && $0.position == 1 ? BrainArgument(name: "detection_x", position: 1, value: .text("0.5")) : $0 })
        }
        #expect(throws: refusal(.duplicateArgument("window", position: 0))) { _ = try rebuild(args + [BrainArgument(name: "window", position: 0, value: .text("x"))]) }
        #expect(throws: refusal(.positionsNotContiguous("detection_label"))) { _ = try rebuild(args.filter { !($0.name == "detection_label" && $0.position == 1) }) }
        #expect(throws: refusal(.positionsNotContiguous("detection_state"))) { _ = try rebuild(args + [BrainArgument(name: "detection_state", position: 5, value: .text("on"))]) }
        #expect(throws: refusal(.unknownCode(argument: "detection_kind", code: "gadget"))) {
            _ = try rebuild(args.map { $0.name == "detection_kind" && $0.position == 0 ? BrainArgument(name: "detection_kind", position: 0, value: .text("gadget")) : $0 })
        }
        #expect(throws: refusal(.nonFiniteArgument("detection_y", position: 0))) {
            _ = try rebuild(args.map { $0.name == "detection_y" && $0.position == 0 ? BrainArgument(name: "detection_y", position: 0, value: .real(.infinity)) : $0 })
        }
        #expect(throws: refusal(.missingArgument("detection_count"))) { _ = try rebuild(args.filter { $0.name != "detection_count" }) }
        let record = try BrainApplicationCommand(key: .record(eventID: "e2"), bundleID: "test.app", requestedAtMS: 5,
                                                 input: .record(verb: .click, target: detection("X"), effect: try TransitionEffectRecord(effect: "menuOpened:A|B")))
        #expect(throws: refusal(.forbiddenArgument("effect_item"))) {
            _ = try rebuild(record.arguments.filter { $0.name != "effect_kind" }, key: record.key)
        }
        #expect(throws: refusal(.positionsNotContiguous("effect_item"))) {
            _ = try rebuild(record.arguments.filter { !($0.name == "effect_item" && $0.position == 0) }, key: record.key)
        }
        #expect(throws: refusal(.unknownCode(argument: "verb", code: "tap"))) {
            _ = try rebuild(record.arguments.map { $0.name == "verb" ? BrainArgument(name: "verb", position: 0, value: .text("tap")) : $0 }, key: record.key)
        }
        #expect(throws: BrainProjectionError.malformedEffect("stateFlip", .missingState)) {
            _ = try rebuild(record.arguments.filter { $0.name != "effect_item" }.map {
                $0.name == "effect_kind" ? BrainArgument(name: "effect_kind", position: 0, value: .text("stateFlip")) : $0 }, key: record.key)
        }
    }

    @Test("the comparison is exact field by field: absence apart from empty text, bytes not Unicode equivalence, NUL and separators, distinct REALs, order, pixel-only detections, the requested instant")
    func exactComparison() throws {
        let base = try observe([detection("Café"), detection("Mute", y: 0.3)])
        #expect(base.hasSameInput(as: try observe([detection("Café"), detection("Mute", y: 0.3)])))
        let variants: [(String, BrainApplicationCommand)] = [
            ("window absent", try observe([detection("Café"), detection("Mute", y: 0.3)], window: nil)),
            ("window empty", try observe([detection("Café"), detection("Mute", y: 0.3)], window: "")),
            ("decomposed é", try observe([detection("Cafe\u{301}"), detection("Mute", y: 0.3)])),
            ("NUL inside", try observe([detection("Café\u{0}"), detection("Mute", y: 0.3)])),
            ("separator inside", try observe([detection("Café|Mute"), detection("Mute", y: 0.3)])),
            ("next REAL", try observe([detection("Café"), detection("Mute", y: 0.3.nextUp)])),
            ("swapped order", try observe([detection("Mute", y: 0.3), detection("Café")])),
            ("an extra pixel-only icon", try observe([detection("Café"), detection("Mute", y: 0.3), detection("", x: 0.9, kind: .icon)])),
            ("a state", try observe([detection("Café", state: .off), detection("Mute", y: 0.3)])),
            ("one millisecond later", try observe([detection("Café"), detection("Mute", y: 0.3)], at: t0.addingTimeInterval(0.001))),
        ]
        #expect("Cafe\u{301}" == "Café", "Swift's String equality would hide this one")
        for (name, variant) in variants {
            #expect(!base.hasSameInput(as: variant), Comment(rawValue: name))
            #expect(!variant.hasSameInput(as: base), Comment(rawValue: name))
        }
        let names = try ["", " ", "Send", "Send\u{0}"].map { try BrainApplicationCommand.setName($0, anchorKey: "k", in: "test.app", eventID: "e", requestedAt: t0) }
        for (i, lhs) in names.enumerated() {
            for (j, rhs) in names.enumerated() { #expect(lhs.hasSameInput(as: rhs) == (i == j)) }
        }
        let flip = try TransitionEffectRecord(effect: "menuOpened:A|B"), flop = try TransitionEffectRecord(effect: "menuOpened:B|A")
        let one = try BrainApplicationCommand(key: .record(eventID: "e"), bundleID: "test.app", requestedAtMS: 1,
                                              input: .record(verb: .click, target: detection("X"), effect: flip))
        let two = try BrainApplicationCommand(key: .record(eventID: "e"), bundleID: "test.app", requestedAtMS: 1,
                                              input: .record(verb: .click, target: detection("X"), effect: flop))
        let none = try BrainApplicationCommand(key: .record(eventID: "e"), bundleID: "test.app", requestedAtMS: 1,
                                               input: .record(verb: .click, target: detection("X"), effect: nil))
        let empty = try BrainApplicationCommand(key: .record(eventID: "e"), bundleID: "test.app", requestedAtMS: 1,
                                                input: .record(verb: .click, target: detection("X"), effect: try TransitionEffectRecord(effect: "menuOpened:")))
        #expect(!one.hasSameInput(as: two) && !none.hasSameInput(as: empty) && !one.hasSameInput(as: none))
        #expect(one.inputDigest != two.inputDigest, "the digest differs too, but it only reports")
    }

    @Test("C1: a stored detection count is checked against the detections received, never used as a size: a negative count, a count of rows that are not there or detections outside it are typed refusals, zero is an empty ingest")
    func declaredCountAgainstRows() throws {
        let two = try observe([detection("Send"), detection("Mute", y: 0.3)], window: nil)
        func rebuild(count: Int64, from arguments: [BrainArgument]) throws -> BrainApplicationCommand {
            let rows = arguments.filter { $0.name != "detection_count" } + [BrainArgument(name: "detection_count", position: 0, value: .integer(count))]
            return try BrainApplicationCommand(key: two.key, bundleID: two.bundleID, requestedAtMS: two.requestedAtMS, arguments: rows, applicationID: 9)
        }
        func refusal(_ declared: Int64, _ found: Int) -> BrainApplicationError {
            .malformedApplication(applicationID: 9, malformation: .detectionCount(declared: declared, found: found))
        }
        #expect(try rebuild(count: 0, from: []).hasSameInput(as: try observe([], window: nil)))
        #expect(try rebuild(count: 2, from: two.arguments).hasSameInput(as: two))
        #expect(throws: refusal(-1, 0)) { _ = try rebuild(count: -1, from: []) }
        #expect(throws: refusal(.min, 2)) { _ = try rebuild(count: .min, from: two.arguments) }
        #expect(throws: refusal(1, 0)) { _ = try rebuild(count: 1, from: []) }
        #expect(throws: refusal(3, 2)) { _ = try rebuild(count: 3, from: two.arguments) }
        #expect(throws: refusal(1_000_000, 2)) { _ = try rebuild(count: 1_000_000, from: two.arguments) }
        #expect(throws: refusal(1, 2)) { _ = try rebuild(count: 1, from: two.arguments) }
        let shifted = two.arguments.map { $0.name.hasPrefix("detection_") && $0.position == 1 ? BrainArgument(name: $0.name, position: 7, value: $0.value) : $0 }
        #expect(throws: BrainApplicationError.malformedApplication(applicationID: 9, malformation: .positionsNotContiguous("detection_kind"))) {
            _ = try rebuild(count: 2, from: shifted)
        }
        let negative = two.arguments.map { $0.name.hasPrefix("detection_") && $0.position == 1 ? BrainArgument(name: $0.name, position: -1, value: $0.value) : $0 }
        #expect(throws: BrainApplicationError.malformedApplication(applicationID: 9, malformation: .positionsNotContiguous("detection_kind"))) {
            _ = try rebuild(count: 2, from: negative)
        }
    }

    @Test("C2: a key is its bytes: canonically equivalent event ids are two keys, in a set and as inputs; a key built again is the same key; phase, ordinal and operation each tell keys apart")
    func keysAreBytes() throws {
        let composed = "café", decomposed = "cafe\u{301}"
        #expect(composed == decomposed && Array(composed.utf8) != Array(decomposed.utf8), "Swift's String equality would make these one key")
        func keys(_ id: String) -> [BrainApplicationKey] {
            [.observe(CaptureSampleKey(eventID: id, phase: .after)), .observe(CaptureSampleKey(eventID: id, phase: .before)),
             .observe(CaptureSampleKey(eventID: id, phase: .after, ordinal: 1)), .record(eventID: id), .setName(eventID: id)]
        }
        let all = keys(composed) + keys(decomposed)
        for (i, lhs) in all.enumerated() {
            for (j, rhs) in all.enumerated() {
                #expect((lhs == rhs) == (i == j), Comment(rawValue: "\(i) \(lhs.identity) against \(j) \(rhs.identity)"))
            }
        }
        #expect(Set(all).count == 10)
        #expect(Set(all + keys("caf" + "é") + keys("cafe" + "\u{301}")).count == 10, "a key built again from the same bytes is the same key")
        var indexed: [BrainApplicationKey: Int] = [:]
        for (index, key) in all.enumerated() { indexed[key] = index }
        #expect(indexed.count == 10 && indexed[.record(eventID: decomposed)] == 8 && indexed[.record(eventID: composed)] == 3)
        let lhs = try BrainApplicationCommand(key: .observe(CaptureSampleKey(eventID: composed, phase: .after)), bundleID: "test.app",
                                              requestedAtMS: 0, input: .observe(window: nil, detections: []))
        let rhs = try BrainApplicationCommand(key: .observe(CaptureSampleKey(eventID: decomposed, phase: .after)), bundleID: "test.app",
                                              requestedAtMS: 0, input: .observe(window: nil, detections: []))
        #expect(!lhs.hasSameInput(as: rhs) && !rhs.hasSameInput(as: lhs))
        #expect(lhs.hasSameInput(as: try BrainApplicationCommand(key: .observe(CaptureSampleKey(eventID: "caf" + "é", phase: .after)),
                                                                 bundleID: "test.app", requestedAtMS: 0, input: .observe(window: nil, detections: []))))
    }

    @Test("−0.0 and +0.0 are one number in a geometric argument, by the contract's IEEE equality, while texts stay bytes; the digest tells the two apart, and only reports")
    func signedZeroIsOneNumber() throws {
        let negative = try observe([BrainDetection(kind: .control, label: "Send", bounds: NormalizedRect(x: -0.0, y: 0.1, width: 0.03, height: 0.017))])
        let positive = try observe([BrainDetection(kind: .control, label: "Send", bounds: NormalizedRect(x: 0.0, y: 0.1, width: 0.03, height: 0.017))])
        #expect(negative.hasSameInput(as: positive) && positive.hasSameInput(as: negative))
        #expect(negative.inputDigest != positive.inputDigest)
        let decomposed = try observe([BrainDetection(kind: .control, label: "Cafe\u{301}", bounds: NormalizedRect(x: -0.0, y: 0.1, width: 0.03, height: 0.017))])
        let composed = try observe([BrainDetection(kind: .control, label: "Café", bounds: NormalizedRect(x: 0.0, y: 0.1, width: 0.03, height: 0.017))])
        #expect(!decomposed.hasSameInput(as: composed))
    }
}
