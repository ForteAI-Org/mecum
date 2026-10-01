import EngineCore
import Foundation
import PerceptionCore

/// MenuStep remembers a native path opening one window. Menu presence must be read through menus,
/// never inferred from a window scene or historical enabled flags.
public struct MenuStep: Sendable, Hashable {
    public struct Call: Sendable, Equatable {
        public let path: [String]
        public let expectedWindow: String
        public init(path: [String], expectedWindow: String) { self.path = path; self.expectedWindow = expectedWindow }
    }
    public let path: [String]
    public let expectedWindow: String
    public init(path: [String], expectedWindow: String) { self.path = path; self.expectedWindow = expectedWindow }
}

extension MenuStep: LearnableStep {
    var tool: ExperienceStep.Tool { .menu }
    var control: String { path.joined(separator: " > ") }
    var arguments: [String: String] { ["path": control, "expect_window": expectedWindow] }
    var terms: Set<String> { Set(GoalPhrase.tokens(control) + GoalPhrase.tokens(expectedWindow)) }
    var summary: String { "menu '\(control)' to open the window '\(expectedWindow)'" }
    var key: String {
        // Length prefixes keep path components distinct even if a title contains separators.
        (["menu"] + path.map(MenuCatalog.key) + [MenuCatalog.key(expectedWindow)])
            .map { "\($0.utf8.count):\($0)" }.joined()
    }
    var experienceStep: ExperienceStep { .menu(self) }

    func encodeFields(to container: inout KeyedEncodingContainer<ExperienceStep.CodingKeys>) throws {
        try container.encode(path, forKey: .path)
        try container.encode(expectedWindow, forKey: .expectedWindow)
    }
    init(control: String, tool: ExperienceStep.Tool,
         from container: KeyedDecodingContainer<ExperienceStep.CodingKeys>) throws {
        let path = try container.decode([String].self, forKey: .path)
        let expected = try container.decode(String.self, forKey: .expectedWindow)
        guard (2...8).contains(path.count), path.allSatisfy({ !MenuCatalog.key($0).isEmpty }),
              !MenuCatalog.key(expected).isEmpty, control == path.joined(separator: " > ") else {
            throw DecodingError.dataCorruptedError(forKey: .path, in: container, debugDescription: "invalid native menu path")
        }
        self.init(path: path, expectedWindow: expected)
    }
    static var admission: TurnAdmission.Reason { .admittedSingleMenu }
    static func evidence(in proof: ActEvidence) -> MenuEvidence? { proof.menu }
    init(proving evidence: MenuEvidence, for call: Call) {
        self.init(path: evidence.path, expectedWindow: evidence.expectedWindow)
    }
    static func unverified(_ evidence: MenuEvidence, kind: ActOutcomeKind) -> TurnAdmission.Reason? {
        evidence.isVerified && kind == .foundActed ? nil : .notVerified
    }
    static func isAnswered(_ call: Call, by evidence: MenuEvidence) -> Bool {
        call.path.map(MenuCatalog.key) == evidence.path.map(MenuCatalog.key)
            && call.expectedWindow == evidence.expectedWindow
    }
    static func goalRefusal(_ request: String, call: Call, evidence: MenuEvidence) -> TurnAdmission.Reason? {
        MenuGoal.refusal(request, window: evidence.expectedWindow, context: evidence.windowTitles)
    }
    func isRepeated(by other: MenuStep) -> Bool {
        path.map(MenuCatalog.key) == other.path.map(MenuCatalog.key) && expectedWindow == other.expectedWindow
    }
    func recallMatch(_ request: String, tokens: Set<String>, in record: ExperienceRecord)
        -> (match: Recall.Match, isGoal: Bool)? {
        guard MenuGoal.refusal(request, window: expectedWindow, context: record.latestProof?.windowTitles ?? []) == nil else { return nil }
        return Self.goalMatch(tokens, in: record)
    }
    func resolutions(in scene: SceneSnapshot) -> [SceneSnapshot.Resolution] { [] }
    var sightedLabels: [String] { [] }
    var briefing: RecallBriefing.StepDetail {
        .init(opens: "the window '\(expectedWindow)'", path: path, expectedWindow: expectedWindow,
              guidance: " Read menus again before using this historical path with menu and expect_window. "
                + "The path does not name a window control. Unknown availability is not permission to execute.")
    }
}
