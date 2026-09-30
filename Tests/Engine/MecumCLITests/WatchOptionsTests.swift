import Testing
@testable import mecum

@MainActor
@Suite
struct WatchOptionsTests {
    @Test func parsesAppAndDiagnostics() throws {
        let options = try WatchOptions(arguments: ["Pro Tools", "--json", "--no-hover", "--duration", "12", "--interval-ms", "250"])
        #expect(options.app == "Pro Tools")
        #expect(options.json && !options.hover)
        #expect(options.duration == 12)
        #expect(options.intervalMilliseconds == 250)
    }

    @Test func rejectsInvalidOptionsBeforeStartingListener() {
        for arguments in [["--duration", "nan"], ["--interval-ms", "0"], ["--raw", "--raw"], ["--seat"], ["one", "two"]] {
            #expect(throws: (any Error).self) { try WatchOptions(arguments: arguments) }
        }
    }
}
