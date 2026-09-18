//
//  MisfireCorpusTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

@testable import Memory
import Testing

/// The misfire corpus is data, and these tests are what make it trustworthy data: every case is
/// attributable to a source, both directions are represented, and the recorded `today` column is what
/// recall actually answers, so the corpus loses the moment the engine drifts from it.
@Suite("The misfire corpus")
struct MisfireCorpusTests {

    @Test("every case carries provenance and a reason")
    func provenance() throws {
        let corpus = try MisfireCorpus.load()
        #expect(corpus.schema == 1)
        #expect(!corpus.cases.isEmpty)
        var ids = Set<String>()
        for k in corpus.cases {
            #expect(ids.insert(k.id).inserted, "duplicate case id \(k.id)")
            #expect(!k.input.isEmpty && !k.why.isEmpty && !k.memory.phrase.isEmpty && !k.memory.args.isEmpty, Comment(rawValue: k.id))
            #expect(!k.provenance.isEmpty, Comment(rawValue: k.id))
            for entry in k.provenance {
                #expect(["session", "live-store", "measurement", "derived"].contains(entry.source), Comment(rawValue: k.id))
                #expect(!entry.ref.isEmpty && !entry.quote.isEmpty, Comment(rawValue: k.id))
            }
        }
    }

    @Test("every decision is well formed")
    func wellFormed() throws {
        for k in try MisfireCorpus.load().cases {
            for (label, decision) in [("expected", k.expected), ("today", k.today)] {
                switch decision.decision {
                    case .fire:
                        #expect(decision.tool != nil && !(decision.args?.isEmpty ?? true), "\(k.id).\(label)")
                    case .abstain:
                        #expect(decision.tool == nil && decision.args == nil, "\(k.id).\(label)")
                }
            }
            switch k.verdict {
                case .wrong  : #expect(k.expected.decision == .abstain, Comment(rawValue: k.id))
                case .correct: #expect(k.expected.decision == .fire, Comment(rawValue: k.id))
                case .watch  : #expect(k.today.decision == .abstain && k.expected.decision == .fire, Comment(rawValue: k.id))
            }
        }
    }

    @Test("both classes are represented with weight")
    func bothClasses() throws {
        let cases = try MisfireCorpus.load().cases
        let wrong = cases.filter { $0.verdict == .wrong }, correct = cases.filter { $0.verdict == .correct }
        #expect(wrong.count >= 5)
        #expect(correct.count >= 5)
        #expect(Set(wrong.map(\.classKind)).isSuperset(of: ["deictic", "junk"]))
        #expect(Set(correct.map(\.classKind)).contains("exact-replay"))
        #expect(!Set(correct.map(\.classKind)).isDisjoint(with: ["app-swap", "entity-swap"]))
        let italian = cases.filter { $0.language == "it" }
        #expect(italian.count >= 2)
        #expect(italian.contains { $0.verdict == .wrong && $0.classKind == "deictic" })
    }

    @Test("the corpus is faithful to today's engine")
    func faithful() throws {
        let corpus = try MisfireCorpus.load()
        for k in corpus.cases {
            let got = k.askRecall()
            #expect(got.decision == k.today.decision, "\(k.id): corpus measured \(corpus.measured)")
            if k.today.decision == .fire {
                #expect(got.tool == k.today.tool, Comment(rawValue: k.id))
                #expect(got.args == k.today.args, Comment(rawValue: k.id))
            }
        }
    }

    @Test("field observations are still measured against the field")
    func field() throws {
        var reproduced = 0, refused = 0
        for k in try MisfireCorpus.load().cases {
            guard let observed = k.observed, let tool = observed.tool, let args = observed.args else { continue }
            switch k.verdict {
                case .correct:
                    #expect(k.today.decision == .fire && k.today.tool == tool && k.today.args == args, Comment(rawValue: k.id))
                    reproduced += 1
                case .wrong:
                    #expect(k.today.decision == .abstain, Comment(rawValue: k.id))
                    #expect(k.expected.args != args, Comment(rawValue: k.id))
                    refused += 1
                case .watch:
                    continue
            }
        }
        #expect(reproduced + refused >= 8)
        #expect(refused >= 3)
    }

    @Test("every wrong case abstains and every correct case fires")
    func acceptanceBar() throws {
        var wrong = 0, correct = 0
        for k in try MisfireCorpus.load().cases {
            switch k.verdict {
                case .wrong:
                    wrong += 1
                    #expect(k.askRecall() == .abstain, "\(k.id): \(k.why)")
                case .correct:
                    correct += 1
                    #expect(k.askRecall() == k.expected, "\(k.id): \(k.why)")
                case .watch:
                    continue
            }
        }
        #expect(wrong >= 5)
        #expect(correct >= 5)
    }

    @Test("the pronoun case abstains and names what it refused")
    func pronoun() throws {
        let k = try #require(try MisfireCorpus.load().cases.first { $0.id == "deictic-it-en" })
        #expect(k.askRecall() == .abstain)
        guard case .abstain(let abstention) = k.askRecallAnswer() else {
            Issue.record("expected an abstention")
            return
        }
        #expect(abstention.refused == k.memory.phrase)
        #expect(abstention.narration != nil)
        #expect(k.observed?.args == ["app": "it"])
    }

    @Test("refusals are narrated and silence is reserved for the unknown")
    func narration() throws {
        var narrated = 0, silent = 0
        for k in try MisfireCorpus.load().cases where k.verdict == .wrong {
            guard case .abstain(let abstention) = k.askRecallAnswer() else {
                Issue.record("\(k.id): expected an abstention")
                continue
            }
            if abstention.refused == nil {
                silent += 1
                #expect(abstention.narration == nil, Comment(rawValue: k.id))
            } else {
                narrated += 1
                #expect(abstention.refused == k.memory.phrase, Comment(rawValue: k.id))
                #expect(abstention.narration != nil && abstention.reason.contains(k.memory.phrase), Comment(rawValue: k.id))
            }
        }
        #expect(narrated >= 5)
        #expect(silent >= 1)
    }

    @Test("the human table covers every case")
    func humanTable() throws {
        let table = try MisfireCorpus.humanTable()
        for k in try MisfireCorpus.load().cases {
            #expect(table.contains(k.id), "the table does not list case \(k.id)")
            #expect(table.contains(k.input), "the table does not show the phrase \"\(k.input)\"")
        }
    }
}
