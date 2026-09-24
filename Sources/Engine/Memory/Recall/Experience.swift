//
//  Experience.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

/// Experience is one remembered phrase and the tool call that solved it, with how often the replay
/// worked and failed. Its tokens are the phrase's goal content, derived, never hand-written. `source`
/// names the durable record it was projected from, when there is one, so a decision can cite it.
public struct Experience: Sendable, Equatable {

    public let phrase: String
    public let tokens: [String]
    public let tool: String
    public let argsJSON: String
    public let ok: Int
    public let fail: Int
    public let source: ExperienceID?

    public init(
        phrase  : String,
        tokens  : [String],
        tool    : String,
        argsJSON: String,
        ok      : Int,
        fail    : Int,
        source  : ExperienceID? = nil
    ) {
        self.phrase   = phrase
        self.tokens   = tokens
        self.tool     = tool
        self.argsJSON = argsJSON
        self.ok       = ok
        self.fail     = fail
        self.source   = source
    }

    /// Builds an experience whose tokens come from the phrase itself.
    public init(phrase: String, tool: String, argsJSON: String, ok: Int = 1, fail: Int = 0,
                source: ExperienceID? = nil) {
        self.init(phrase: phrase, tokens: GoalPhrase.tokens(phrase), tool: tool, argsJSON: argsJSON, ok: ok,
                  fail: fail, source: source)
    }

    /// The one reliability rule every recall answer applies: more verified successes than
    /// contradictions. A memory that fails it is never replayed, suggested or hinted.
    public var isTrustworthy: Bool { Self.isTrustworthy(ok: ok, fail: fail) }

    public static func isTrustworthy(ok: Int, fail: Int) -> Bool { ok > fail }
}
