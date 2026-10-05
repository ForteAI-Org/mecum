import EngineCore
import Memory
import PerceptionCore
import Testing
@testable import mecum

@Suite("Batch command")
struct BatchTests {

    private let header = ["batch", "Pro Tools", "--window", "New Paths", "--seat", "--allow-unvalidated-build", "--"]

    @Test("the requested sequence preserves labels and shares one application and window")
    func parsesSequence() throws {
        let plan = try BatchPlan(arguments: header + [
            "select", "Mono", "Stereo", "--then",
            "act", "Auto-create sub paths", "--verb", "set_toggle", "--value", "on", "--then", "act", "Create"
        ])
        #expect(plan.application == "Pro Tools")
        #expect(plan.invocation.options["window"] == "New Paths")
        #expect(plan.steps.count == 3)
        guard case .select(let control, let item) = plan.steps[0].request,
              case .act(let target, let verb, let value, let section) = plan.steps[1].request else {
            Issue.record("wrong step types")
            return
        }
        #expect(control == "Mono" && item == "Stereo")
        #expect(target == "Auto-create sub paths" && section == nil)
        #expect(verb == .setToggle && value == .on)
        #expect(plan.invocation.options["verb"] == nil)
    }

    @Test("invalid later steps and options reject the whole plan before execution", arguments: [
        ["act", "Create", "--then"],
        ["act", "Create", "--then", "act", "Cancel", "--verb", "typo"],
        ["act", "Create", "--then", "select", "Mono"],
        ["act", "Create", "--then", "act", "Auto-create sub paths", "--verb", "set_toggle"],
        ["act", "Create", "--window", "I/O Setup"],
        ["act", "Create", "--dry-run"],
        ["act", "Create", "--value", "on"],
        ["act", "Create", "--section", "one", "--section", "two"],
        ["act", "Create", "--section", "--then", "act", "Cancel"],
        ["select", "Mono", "Stereo", "--allow-destructive"],
        ["select", "Mono", ""],
        ["--then", "act", "Create"],
        []
    ])
    func rejectsMalformedSteps(_ steps: [String]) {
        #expect(throws: (any Error).self) { try BatchPlan(arguments: header + steps) }
    }

    @Test("batch requires a named window, Seat, delimiter and supported shared options", arguments: [
        ["batch", "Pro Tools", "--seat", "--", "act", "Create"],
        ["batch", "Pro Tools", "--window", "New Paths", "--", "act", "Create"],
        ["batch", "Pro Tools", "--window", "New Paths", "--seat", "act", "Create"],
        ["batch", "Pro Tools", "--window", "New Paths", "--seat", "--dry-run", "--", "act", "Create"],
        ["batch", "Pro Tools", "--window", "--seat", "--", "act", "Create"],
        ["batch", "Pro Tools", "--window", "New Paths", "--seat", "--seet", "--", "act", "Create"]
    ])
    func rejectsMalformedHeader(_ words: [String]) {
        #expect(throws: (any Error).self) { try BatchPlan(arguments: words) }
    }

    @Test("steps run once in order; an already-set toggle continues")
    func orderedExecution() async throws {
        let plan = try BatchPlan(arguments: header + [
            "select", "Mono", "Stereo", "--then",
            "act", "Auto-create sub paths", "--verb", "set_toggle", "--value", "on", "--then", "act", "Create"
        ])
        var calls: [Int] = []
        try await BatchSequence.run(plan.steps) { number, _ in
            calls.append(number)
            return number == 2 ? .actedNoop : .foundActed
        }
        #expect(calls == [1, 2, 3])
    }

    @Test("a failed step stops without replaying prior effects or running Create", arguments: [
        ActOutcomeKind.ambiguous, .honestMiss, .actedUnverified, .refused, .actedNoop, .dryRun
    ])
    func stopsOnOutcome(_ kind: ActOutcomeKind) async throws {
        let plan = try BatchPlan(arguments: header + [
            "select", "Mono", "Stereo", "--then", "act", "Auto-create sub paths", "--then", "act", "Create"
        ])
        var calls: [Int] = []
        do {
            try await BatchSequence.run(plan.steps) { number, _ in
                calls.append(number)
                return number == 2 ? kind : .foundActed
            }
            Issue.record("continued after a failed step")
        } catch let error as BatchFailure {
            #expect(error.step == 2 && error.total == 3)
            #expect((error.cause as? ActFailure)?.kind == kind)
        }
        #expect(calls == [1, 2])
    }

    @Test("a thrown delivery error retains its step and stops")
    func thrownFailure() async throws {
        let plan = try BatchPlan(arguments: header + ["act", "First", "--then", "act", "Create"])
        var calls: [Int] = []
        do {
            try await BatchSequence.run(plan.steps) { number, _ in
                calls.append(number)
                throw CancellationError()
            }
            Issue.record("ignored error")
        } catch let error as BatchFailure {
            #expect(error.step == 1)
            #expect(error.cause is CancellationError)
        }
        #expect(calls == [1])
    }

    @Test("cancellation between steps prevents the next action")
    func cancellation() async throws {
        let plan = try BatchPlan(arguments: header + ["act", "First", "--then", "act", "Create"])
        let task = Task { @MainActor in
            var calls: [Int] = []
            do {
                try await BatchSequence.run(plan.steps) { number, _ in
                    calls.append(number)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return .foundActed
                }
                Issue.record("ignored cancellation")
            } catch let error as BatchFailure {
                #expect(error.step == 2)
                #expect(error.cause is CancellationError)
            } catch { Issue.record("unexpected error: \(error)") }
            return calls
        }
        #expect(await task.value == [1])
    }

    // MARK: The header's escapes (S3-e correction)

    @Test("an escape in the header stays an escape: a literal app, window or knowledge, and the real boundary after it")
    func literalHeaderValues() throws {
        let window = try BatchPlan(arguments: ["batch", "App", "--window", "--", "--Window", "--seat", "--", "act", "Create"])
        #expect(window.application == "App" && window.invocation.options["window"] == "--Window")
        #expect(window.steps.map(\.summary) == ["act target=\"Create\" verb=click"])
        let app = try BatchPlan(arguments: ["batch", "--", "--App", "--window", "W", "--seat", "--", "press_key", "return"])
        #expect(app.application == "--App" && app.invocation.options["window"] == "W" && app.steps.count == 1)
        let knowledge = try BatchPlan(arguments: ["batch", "App", "--knowledge", "--", "--", "--window", "--", "--then", "--seat",
                                                  "--", "type_text", "Name", "--", "--then", "--then", "act", "OK"])
        #expect(knowledge.invocation.options["knowledge"] == "--" && knowledge.invocation.options["window"] == "--then")
        #expect(knowledge.steps.map(\.summary) == ["type_text target=\"Name\" text=<6 characters> replace=true",
                                                   "act target=\"OK\" verb=click"])
        // The old form, unchanged: the first -- after a complete header is the boundary.
        let plain = try BatchPlan(arguments: header + ["act", "Create"])
        #expect(plain.invocation.options["window"] == "New Paths" && plain.steps.count == 1)
    }

    @Test("a malformed header is refused before anything runs", arguments: [
        ["batch", "App", "--window", "--"],
        ["batch", "App", "--window", "--", "--W", "--seat"],
        ["batch", "App", "--window", "--seat", "--", "act", "Create"],
        ["batch", "App", "--window", "W", "--seat", "act", "Create"],
        ["batch", "--"],
        ["batch", "App", "--window", "W", "--seat", "--knowledge"],
        ["batch", "App", "--window", "--", "--W", "--seat", "--", "act"],
        ["batch", "App", "Other", "--window", "W", "--seat", "--", "act", "Create"],
    ])
    func malformedHeaders(_ words: [String]) {
        #expect(throws: (any Error).self) { try BatchPlan(arguments: words) }
    }

    @Test("the header's end is found by the grammar: an escaped -- is a word, the first other -- ends it")
    func headerEnd() throws {
        func end(_ words: [String]) throws -> Int? {
            try Words.headerEnd(words.dropFirst(), spec: CommandSpecs.batch, requiredPositionals: 1)
        }
        #expect(try end(["batch", "App", "--seat", "--", "act"]) == 3)
        #expect(try end(["batch", "App", "--window", "--", "--", "--", "act"]) == 5)
        #expect(try end(["batch", "--", "--", "--seat", "--"]) == 4)
        #expect(try end(["batch", "App", "--seat"]) == nil)
        #expect(throws: UsageError.self) { try end(["batch", "App", "--window", "--"]) }
        #expect(throws: UsageError.self) { try end(["batch", "--"]) }
    }
}
