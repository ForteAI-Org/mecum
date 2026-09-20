import Testing
@testable import mecum

@Suite("Peek command parsing")
struct PeekOptionsTests {
    @Test func defaultsFollowTheFrontAppUntilInterrupted() throws {
        let options = try PeekOptions(arguments: [])
        #expect(options.intervalMilliseconds == 500)
        #expect(options.durationSeconds == nil)
        #expect(!options.sectionsOnly && !options.labels && !options.timings)
    }

    @Test func boundedInspectionAndDrawingOptions() throws {
        let options = try PeekOptions(arguments: ["--duration", "2.5", "--interval-ms", "250", "--labels", "--sections-only", "--timings"])
        #expect(options.intervalMilliseconds == 250)
        #expect(options.durationSeconds == 2.5)
        #expect(options.sectionsOnly && options.labels)
        #expect(options.timings)
    }

    @Test(arguments: [["--seat"], ["Pro Tools"], ["--interval-ms"], ["--interval-ms", "0"],
                      ["--duration", "nan"], ["--duration", "inf"], ["--duration", "-1"],
                      ["--labels", "--labels"], ["--interval-ms", "1000000"]])
    func rejectsInvalidOptionsBeforeStarting(_ arguments: [String]) {
        #expect(throws: (any Error).self) { _ = try PeekOptions(arguments: arguments) }
    }
}
