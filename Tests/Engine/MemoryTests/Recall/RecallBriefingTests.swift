//
//  RecallBriefingTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 28/09/2026.
//

import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

/// The guidance a briefing gives the model for each remembered tool, in each context Recall answers:
/// operational only for a suggestion, and never for history or a refusal.
@Suite("A briefing's guidance follows its status")
struct RecallBriefingTests {

    private let bundle = "test.synthetic.mixer"
    private let verifiedAt = Date(timeIntervalSince1970: 1_800_000_000)

    /// One remembered step per tool, learned in the synthetic mixer window, with the request that asks for it.
    private var remembered: [(request: String, step: ExperienceStep)] {
        [
            ("Seleziona Output Busses nel filtro", .select(control: "All Busses", item: "Output Busses")),
            ("Attiva Mute", .setToggle(control: "Mute", section: nil, state: .on)),
            ("Clicca Export", .click(.click, target: "Export", section: nil, opens: .window(title: "Export Settings"))),
            ("Fai doppio clic su Project", .click(.doubleClick, target: "Project", section: nil,
                                                  opens: .window(title: "Project 1"))),
            ("Fai clic destro su Track 1", .click(.rightClick, target: "Track 1", section: nil, opens: .menu)),
        ]
    }

    private func record(_ step: ExperienceStep, phrase: String, failures: Int = 0) -> ExperienceRecord {
        let context = WindowContext(bundleID: bundle, windowTitle: "Synthetic Mixer")!
        let draft = ExperienceDraft(phrase: phrase, step: step, context: context)!
        return ExperienceRecord(id: ExperienceID(step.tool.rawValue), draft: draft, createdAt: verifiedAt,
                                successCount: 1, failureCount: failures, lastVerifiedAt: verifiedAt)
    }

    private func scene(_ labels: [String]) -> SceneSnapshot {
        var scene = SceneSnapshot(
            bundleID: bundle, appName: "Synthetic Mixer", windowTitle: "Synthetic Mixer",
            viewportPixelSize: ViewportPixelSize(width: 800, height: 600),
            elements: labels.enumerated().map { index, label in
                SceneElement(id: "control|\(label.lowercased())", kind: .control, label: label,
                             bounds: NormalizedRect(x: 0.1, y: 0.1 + Double(index) * 0.1, width: 0.1, height: 0.05))
            }
        )
        scene.coverage = .window
        return scene
    }

    private func briefing(_ request: String, _ record: ExperienceRecord, _ context: Recall.Context) throws
        -> RecallBriefing {
        let answer = Recall.suggest(input: request,
                                    in: Recall.World(records: [record], sightings: [], context: context))
        return try #require(RecallBriefing(answer, records: [record]), "\(request)")
    }

    /// The briefing as the prompt carries it: its JSON, which is every word the model reads of it.
    private func json(_ briefing: RecallBriefing) throws -> String {
        let encoder = KnowledgeCoding.makeEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(briefing), as: UTF8.self)
    }

    @Test("history and refusals, in another application or window, unreliable or absent, authorize no action")
    func notSuggestedAuthorizesNothing() throws {
        for (request, step) in remembered {
            let cases: [(String, ExperienceRecord, Recall.Context, String, String)] = [
                ("otherApplication", record(step, phrase: request),
                 Recall.Context(bundleID: "test.synthetic.editor", windowFamily: "syntheticmixer"), "refused",
                 "otherApplication"),
                ("otherWindow", record(step, phrase: request),
                 Recall.Context(bundleID: bundle, windowFamily: "syntheticlog"), "historical", "otherWindow"),
                ("notReliable", record(step, phrase: request, failures: 2), Recall.Context(), "refused",
                 "notReliable"),
                ("absentNow", record(step, phrase: request), Recall.Context(freshScene: scene(["Solo"])), "historical",
                 "absentNow"),
            ]
            for (label, record, context, status, reason) in cases {
                let briefing = try briefing(request, record, context)
                let text = try json(briefing)
                #expect(briefing.status == status, "\(step.tool) \(label)")
                #expect(briefing.reason?.contains(reason) == true, "\(step.tool) \(label)")
                #expect(briefing.guidance.contains("does not authorize"), "\(step.tool) \(label)")
                #expect(briefing.guidance.hasPrefix("Not offered"), "\(step.tool) \(label)")
                #expect(briefing.guidance.contains("Observe first"), "\(step.tool) \(label)")
                #expect(!text.contains("use act"), "\(step.tool) \(label): \(text)")
                #expect(!text.contains("with verb"), "\(step.tool) \(label): \(text)")
            }
        }
        // A request that only shares the remembered phrase's words is history too.
        let select = record(.select(control: "All Busses", item: "Output Busses"),
                            phrase: "Seleziona Output Busses nel filtro e verifica il nuovo valore")
        let lexical = try briefing("Ciao. Seleziona Output Busses nel filtro e verifica il nuovo valore", select,
                                   Recall.Context())
        #expect(lexical.status == "historical" && lexical.reason == "goalNotSingle")
        #expect(lexical.guidance.hasPrefix("Not offered") && !lexical.guidance.contains("use act"))
    }

    @Test("a suggestion keeps the fresh observation first, and only then names the tool that verifies it")
    func suggestedIsOperational() throws {
        for (request, step) in remembered {
            for context in [Recall.Context(), Recall.Context(freshScene: scene([step.control, "Output Busses"]))] {
                let briefing = try briefing(request, record(step, phrase: request), context)
                #expect(briefing.status == "suggested", "\(step.tool)")
                #expect(briefing.guidance.hasPrefix("Observe first."), "\(step.tool)")
                #expect(!briefing.guidance.contains("does not authorize"), "\(step.tool)")
                switch step {
                    case .menu:
                        #expect(briefing.guidance.contains("Read menus again"))
                    case .select:
                        #expect(!briefing.guidance.contains("use act"))
                    case .setToggle:
                        #expect(briefing.guidance.contains("use act with verb set_toggle"))
                    case .click:
                        #expect(briefing.guidance.contains("use act with verb \(step.tool.rawValue) "), "\(step.tool)")
                }
            }
        }
    }
}
