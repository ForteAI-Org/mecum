import XCTest
import CoreGraphics
@testable import Relocation
import LocatorCore

private final class MockRelocator: StepRelocating, @unchecked Sendable {
    var byID: [UUID: RelocationResult] = [:]
    func relocate(_ d: Descriptor) async -> RelocationResult { byID[d.id] ?? .notFound }
}

private final class MockActuator: StepActuating, @unchecked Sendable {
    private(set) var focused: [String] = []
    private(set) var actuatedIDs: [UUID] = []
    var actuateSucceeds = true
    func focus(bundleID: String) async { focused.append(bundleID) }
    func actuate(descriptor: Descriptor, result: RelocationResult) async -> Bool {
        actuatedIDs.append(descriptor.id); return actuateSucceeds
    }
}

final class FlowRunnerTests: XCTestCase {
    private func descriptor(_ id: UUID) -> Descriptor { makeDescriptor(id: id) }

    func testRunsAllStepsFocusesAppAndActuates() async {
        let a = UUID(), b = UUID()
        let flow = Flow(name: "f", bundleID: "com.avid.ProTools", stepIDs: [a, b], created: Date(timeIntervalSince1970: 1))
        let reloc = MockRelocator()
        reloc.byID[a] = RelocationResult(elementRectScreenPt: .init(x: 0, y: 0, width: 1, height: 1), method: .axPath, confidence: 1)
        reloc.byID[b] = RelocationResult(elementRectScreenPt: .init(x: 0, y: 0, width: 1, height: 1), method: .geometryNCC, confidence: 0.9)
        let act = MockActuator()

        let report = await FlowRunner(relocator: reloc, actuator: act)
            .run(flow, descriptors: [a: descriptor(a), b: descriptor(b)], stepDelaySeconds: 0, focusSettleSeconds: 0)

        XCTAssertEqual(act.focused, ["com.avid.ProTools"])
        XCTAssertEqual(act.actuatedIDs, [a, b])
        XCTAssertTrue(report.allActuated)
        XCTAssertEqual(report.steps.map(\.method), [.axPath, .geometryNCC])
    }

    func testMissingDescriptorIsSkippedNotCrashed() async {
        let a = UUID(), missing = UUID()
        let flow = Flow(name: "f", bundleID: "com.x", stepIDs: [a, missing], created: Date(timeIntervalSince1970: 1))
        let reloc = MockRelocator()
        reloc.byID[a] = RelocationResult(elementRectScreenPt: .init(x: 0, y: 0, width: 1, height: 1), method: .axPath, confidence: 1)
        let act = MockActuator()

        let report = await FlowRunner(relocator: reloc, actuator: act)
            .run(flow, descriptors: [a: descriptor(a)], stepDelaySeconds: 0, focusSettleSeconds: 0)

        XCTAssertEqual(report.steps.count, 2)
        XCTAssertTrue(report.steps[0].actuated)
        XCTAssertFalse(report.steps[1].relocated)   // missing descriptor → skipped
        XCTAssertFalse(report.allActuated)
        XCTAssertEqual(act.actuatedIDs, [a])
    }

    func testRelocationMissIsNotActuated() async {
        let a = UUID()
        let flow = Flow(name: "f", bundleID: "com.x", stepIDs: [a], created: Date(timeIntervalSince1970: 1))
        let reloc = MockRelocator()   // no entry → .notFound
        let act = MockActuator()

        let report = await FlowRunner(relocator: reloc, actuator: act)
            .run(flow, descriptors: [a: descriptor(a)], stepDelaySeconds: 0, focusSettleSeconds: 0)

        XCTAssertFalse(report.steps[0].relocated)
        XCTAssertFalse(report.steps[0].actuated)
        XCTAssertTrue(act.actuatedIDs.isEmpty)
    }

    func testStopOnMissAbortsMidFlowAndSkipsLaterSteps() async {
        let a = UUID(), b = UUID(), c = UUID()
        let flow = Flow(name: "f", bundleID: "com.x", stepIDs: [a, b, c], created: Date(timeIntervalSince1970: 1))
        let reloc = MockRelocator()
        reloc.byID[a] = RelocationResult(elementRectScreenPt: .init(x: 0, y: 0, width: 1, height: 1), method: .axPath, confidence: 1)
        // b → .notFound (no entry). c WOULD succeed but must never be attempted after the abort.
        reloc.byID[c] = RelocationResult(elementRectScreenPt: .init(x: 0, y: 0, width: 1, height: 1), method: .axPath, confidence: 1)
        let act = MockActuator()

        let report = await FlowRunner(relocator: reloc, actuator: act)
            .run(flow, descriptors: [a: descriptor(a), b: descriptor(b), c: descriptor(c)], stepDelaySeconds: 0, focusSettleSeconds: 0)

        XCTAssertEqual(report.steps.count, 2)        // aborted right after step 2's miss
        XCTAssertEqual(act.actuatedIDs, [a])         // step 3 never ran
        XCTAssertFalse(report.allActuated)
    }

    func testStopOnMissFalseContinuesPastMiss() async {
        let a = UUID(), b = UUID(), c = UUID()
        let flow = Flow(name: "f", bundleID: "com.x", stepIDs: [a, b, c], created: Date(timeIntervalSince1970: 1))
        let reloc = MockRelocator()
        reloc.byID[a] = RelocationResult(elementRectScreenPt: .init(x: 0, y: 0, width: 1, height: 1), method: .axPath, confidence: 1)
        reloc.byID[c] = RelocationResult(elementRectScreenPt: .init(x: 0, y: 0, width: 1, height: 1), method: .axPath, confidence: 1)
        let act = MockActuator()

        let report = await FlowRunner(relocator: reloc, actuator: act)
            .run(flow, descriptors: [a: descriptor(a), b: descriptor(b), c: descriptor(c)],
                 stepDelaySeconds: 0, focusSettleSeconds: 0, stopOnMiss: false)

        XCTAssertEqual(report.steps.count, 3)        // partial replay: all steps attempted
        XCTAssertEqual(act.actuatedIDs, [a, c])      // b missed, c still actuated
    }

    func testStopOnMissAbortsWhenRelocatedButActuateFails() async {
        // An element that resolves but doesn't actuate (e.g. offscreen no-op / AXPress refused) must also
        // abort — gating on !actuated, not just !relocated.
        let a = UUID(), b = UUID()
        let flow = Flow(name: "f", bundleID: "com.x", stepIDs: [a, b], created: Date(timeIntervalSince1970: 1))
        let reloc = MockRelocator()
        reloc.byID[a] = RelocationResult(elementRectScreenPt: .init(x: 0, y: 0, width: 1, height: 1), method: .geometryNCC, confidence: 1)
        reloc.byID[b] = RelocationResult(elementRectScreenPt: .init(x: 0, y: 0, width: 1, height: 1), method: .geometryNCC, confidence: 1)
        let act = MockActuator(); act.actuateSucceeds = false

        let report = await FlowRunner(relocator: reloc, actuator: act)
            .run(flow, descriptors: [a: descriptor(a), b: descriptor(b)], stepDelaySeconds: 0, focusSettleSeconds: 0)

        XCTAssertEqual(report.steps.count, 1)        // step 1 relocated but didn't actuate → abort
        XCTAssertFalse(report.steps[0].actuated)
    }
}
