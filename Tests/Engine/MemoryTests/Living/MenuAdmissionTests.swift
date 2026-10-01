import EngineCore
import Foundation
@testable import Memory
import Testing

@Suite("Native menu memory keeps path and verified effect")
struct MenuAdmissionTests {
    let proof = MenuEvidence(bundleID: "test.editor", windowTitle: "Edit", path: ["Setup", "I/O..."],
                             expectedWindow: "I/O Setup", effect: .openedWindow)
    func decision(_ request: String, effect: MenuEvidence.Effect = .openedWindow,
                  path: [String] = ["Setup", "I/O..."], kind: ActOutcomeKind = .foundActed) -> TurnAdmission.Decision {
        let evidence = MenuEvidence(bundleID: proof.bundleID, windowTitle: proof.windowTitle, path: proof.path,
                                    expectedWindow: proof.expectedWindow, effect: effect)
        return TurnAdmission.decide(.init(request: request, attempts: [
            .preparation("menus"), .preparation("resolve_action"),
            .menu(.init(path: path, expectedWindow: proof.expectedWindow), kind: kind, evidence: evidence)
        ], ending: .completed))
    }
    @Test func learnsAnOpeningNotAPointerClick() throws {
        let result = decision("Apri la finestra I/O Setup.")
        #expect(result.reason == .admittedSingleMenu)
        guard case .promote(let draft, let saved) = result.action else { Issue.record("must promote"); return }
        #expect(saved.menu == proof)
        #expect(draft.step.tool == .menu)
        let encoded = try JSONEncoder().encode(draft.step)
        #expect(try JSONDecoder().decode(ExperienceStep.self, from: encoded) == draft.step)
        let proofJSON = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(ActEvidence.self, from: proofJSON) == saved)
    }
    @Test func uncertainDeliveryWrongArgumentsAndCompoundGoalsNeverLearn() {
        #expect(decision("Apri I/O Setup", effect: .unverified).reason == .notVerified)
        #expect(decision("Apri I/O Setup", kind: .actedUnverified).reason == .notVerified)
        #expect(decision("Apri I/O Setup", path: ["File", "Export"]).reason == .argumentsDoNotMatchEvidence)
        #expect(!decision("Non aprire I/O Setup").reason.verifiesStep)
        #expect(!decision("Apri I/O Setup e poi clicca Default").reason.verifiesStep)
        #expect(!decision("Apri Playback Engine").reason.verifiesStep)
    }
}
