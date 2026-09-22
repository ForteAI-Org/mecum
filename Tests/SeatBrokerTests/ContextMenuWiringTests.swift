//
//  ContextMenuWiringTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 18/09/2026.
//

import CoreGraphics
import Foundation
import SeatCore
import TargetReader
import Testing
@testable import SeatBroker

/// The wiring around `ContextMenuChoice`, which the choice's own suite does not
/// reach: where the right click is aimed, which of the two readings of the menu
/// the item click is measured in, what a refusal leaves in the step history, and
/// that the planner is told the action exists at all.
///
/// Opening the menu and posting inside it need a live seat, so those two calls
/// are not exercised here. What is exercised is everything decided before them,
/// which is where a refusal is complete: no point chosen means no click posted.
@Suite("Wiring a contextual menu choice into a step")
struct ContextMenuWiringTests {

    private static func item(_ title: String, enabled: Bool = true,
                             frame: CGRect? = CGRect(x: 420, y: 320, width: 180, height: 22)) -> ObservedMenuItem {
        ObservedMenuItem(title: title, isEnabled: enabled, isSelected: false, hasSubmenu: false, frame: frame)
    }

    /// The menu opens where an ordinary click would land, so the right click is
    /// aimed through the same element geometry and not through a second rule.
    @Test func theRightClickIsAimedWhereAnOrdinaryClickWouldLand() throws {
        let scene = sceneOfOneElement
        let location = try ActionExecutor.location(ofElement: 1, in: scene, frame: anyFrame)
        #expect(try ActionExecutor.inputs(for: .click(element: 1), in: scene, frame: anyFrame)
                == [.command(.click(location))])
        #expect(try ActionExecutor.inputs(for: .click(element: 1, count: 2), in: scene, frame: anyFrame)
                == [.command(.click(location, count: 2))])
        #expect(throws: SeatBrokerError.self) {
            try ActionExecutor.location(ofElement: 7, in: scene, frame: anyFrame)
        }
    }

    /// The reader's rectangle and the observation's are two readings of the same
    /// menu, and the click is admitted against the second. The offset into the
    /// first is what carries over, never the absolute point.
    @Test func theItemClickIsMeasuredInTheMenuTheObservationDelivered() {
        let read = CGRect(x: 400, y: 300, width: 200, height: 120)
        let observed = CGRect(x: 404, y: 306, width: 200, height: 120)
        #expect(ContextMenuChoice.screenPoint(CGPoint(x: 490, y: 333), readAt: read, observedAt: observed)
                == CGPoint(x: 494, y: 339))
        // The two agreeing is the ordinary case and must not move the point.
        #expect(ContextMenuChoice.screenPoint(CGPoint(x: 490, y: 333), readAt: read, observedAt: read)
                == CGPoint(x: 490, y: 333))
    }

    /// A title the menu does not offer chooses nothing at all: there is no point
    /// to aim at, so nothing is posted inside the menu, and the sentence the
    /// planner reads is the choice's own.
    @MainActor @Test func aTitleTheMenuDoesNotOfferChoosesNothingAndKeepsItsReason() {
        let menu = ObservedContextMenu.items([Self.item("Apri"), Self.item("Duplica")])
        let refused = SeatDriver.choice(of: "Incolla", in: menu)
        #expect(refused.point == nil)
        #expect(refused.note == expectedRefusal("Incolla", in: menu))
        #expect(refused.note.contains("Apri, Duplica"))
    }

    /// A menu nobody can read by title says so in its own words, so the next
    /// decision looks for another route instead of repeating the same step.
    @MainActor @Test func aMenuThatCannotBeReadByTitleSaysSoRatherThanBeingEmpty() {
        let menu = ObservedContextMenu.drawnOutsideTheAccessibilityTree(
            frame: CGRect(x: 400, y: 300, width: 200, height: 120))
        let refused = SeatDriver.choice(of: "Incolla", in: menu)
        #expect(refused.point == nil)
        #expect(refused.note == expectedRefusal("Incolla", in: menu))
    }

    /// A matched row answers the point the choice answered, in the reader's own
    /// coordinates, and a note that names what was chosen.
    @MainActor @Test func aMatchedRowAnswersItsOwnCentreAndNamesTheItem() {
        let menu = ObservedContextMenu.items([Self.item("Apri"), Self.item("Incolla")])
        let chosen = SeatDriver.choice(of: "Incolla", in: menu)
        #expect(chosen.point == CGPoint(x: 510, y: 331))
        #expect(chosen.note.contains("Incolla"))
    }

    /// The history is what the next decision reads, and a menu's outcome is not
    /// in the verification: a refusal by title changes no pixel.
    @MainActor @Test func theStepHistoryCarriesTheMenusOwnOutcome() {
        let menu = ObservedContextMenu.items([Self.item("Apri")])
        let reason = expectedRefusal("Incolla", in: menu)
        let line = AgentPlanner.historyLine(step: 2, report: report(
            action: .menu(element: 3, item: "Incolla"), note: reason))
        #expect(line.hasPrefix("step 2: menu [3] \"Incolla\" Documenti → posted, nothing observed to change"))
        #expect(line.contains(reason))
    }

    /// Every other action's line is untouched: nothing was added to it.
    @MainActor @Test func aStepWithNoNoteOfItsOwnReadsExactlyAsItDid() {
        #expect(AgentPlanner.historyLine(step: 1, report: report(action: .click(element: 3), note: nil))
                == "step 1: click [3] Documenti → posted, nothing observed to change")
    }

    /// The model cannot choose an action it was never given, so the target and
    /// its item title are part of the plan vocabulary.
    @Test func aMenuStepIsPartOfThePlanVocabulary() throws {
        let scene = sceneOfThreeElements
        let raw = RawPlan(status: "plan", reason: "", steps: [
            .init(target: "2:menu", text: "Incolla", reason: "paste through the menu"),
        ])
        #expect(try PlanSchema.decision(from: raw, observation: scene).steps.map(\.action)
                == [.menu(element: 2, item: "Incolla")])
        // A menu step names an item or it names nothing at all.
        #expect(throws: PlanValidationError.self) {
            try PlanSchema.decision(
                from: RawPlan(status: "plan", reason: "", steps: [.init(target: "2:menu", text: nil, reason: "")]),
                observation: scene)
        }
    }

    /// The one fact the planner needs about this seat, in both prompt sizes.
    @Test func thePlannerIsToldAShortcutAMenuResolvesDoesNotWorkInThisSeat() {
        for compact in [false, true] {
            let prompt = PlannerPrompt.build(goal: "copy the address", app: "Finder", windowTitle: "Documenti",
                                             observation: sceneOfThreeElements, history: [],
                                             applications: "Finder", maximumSteps: 4, compact: compact)
            #expect(prompt.contains("<index>:menu"))
            #expect(prompt.contains("Command-C"))
            #expect(prompt.contains("Command-V"))
        }
    }

    // MARK: Fixtures

    private func expectedRefusal(_ item: String, in menu: ObservedContextMenu) -> String {
        guard case .refused(let why) = ContextMenuChoice.choosing(item, in: menu) else { return "" }
        return why
    }

    private func report(action: SemanticAction, note: String?) -> ActionReport {
        ActionReport(action: action, targetLabel: "Documenti", before: sceneOfThreeElements,
                     after: sceneOfThreeElements,
                     verification: VerificationResult(outcome: .posted, sceneChanged: false,
                                                      effect: nil, pixelDifference: nil),
                     eventCount: 4, duration: .milliseconds(10), note: note)
    }
}

private let blankImage = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!

private let sceneOfOneElement = SceneObservation(image: blankImage, elements: [
    SceneElement(index: 1, identity: "a", kind: "control", label: "Documenti", role: "AXRow", state: nil,
                 bounds: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.2)),
], text: "", token: "t")

private let sceneOfThreeElements = SceneObservation(image: blankImage, elements: (1...3).map {
    SceneElement(index: $0, identity: "e\($0)", kind: "control", label: "E\($0)", role: nil, state: nil,
                 bounds: CGRect(x: 0, y: 0, width: 0.1, height: 0.1))
}, text: "", token: "t")

private let anyFrame = FrameGeometryObservation(
    source: .window(WindowIdentity(
        process: ProcessIdentity(processID: 42, serialNumberHigh: 1, serialNumberLow: 2),
        windowNumber: 1,
        ownerConnectionID: 3
    )),
    screenRect: CGRect(x: 0, y: 0, width: 100, height: 100),
    contentRectInSurface: CGRect(x: 0, y: 0, width: 100, height: 100),
    scaleFactor: 1, contentScale: 1, pixelSize: CGSize(width: 100, height: 100),
    version: GeometryObservationVersion(observerGeneration: 1, sequence: 1),
    capturesFullWindow: true)
