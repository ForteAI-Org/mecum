import SeatCore
@testable import SeatInput
import Testing

/// UserFocusRestorerTests cover the consumer's exact-window request and the
/// absence of a second activation route after a local refusal.
@MainActor
@Suite("Requesting the prepared consumer window")
struct UserFocusRestorerTests {

    @Test("Handback requests only the attested local number")
    func exactLocalWindow() throws {
        var calls: [String] = []
        let code = try UserFocusRestorer.requestFront(
            processID: 101,
            windowNumber: 801,
            consumerProcessID: 101,
            requestLocal: { calls.append("local \($0)"); return true },
            requestRemote: { calls.append("remote"); return -1 }
        )
        #expect(code == 0)
        #expect(calls == ["local 801"])
    }

    @Test("A subsequent handback uses its fresh local destination")
    func ordinaryLocalWindow() throws {
        var calls: [String] = []
        _ = try UserFocusRestorer.requestFront(
            processID: 101,
            windowNumber: 801,
            consumerProcessID: 101,
            requestLocal: { calls.append("local \($0)"); return true },
            requestRemote: { calls.append("remote"); return -1 }
        )
        let code = try UserFocusRestorer.requestFront(
            processID: 101,
            windowNumber: 802,
            consumerProcessID: 101,
            requestLocal: { calls.append("local \($0)"); return true },
            requestRemote: { calls.append("remote"); return -1 }
        )
        #expect(code == 0)
        #expect(calls == ["local 801", "local 802"])
    }

    @Test("An absent local destination cannot activate through a different route")
    func absentLocalWindow() {
        var calls: [String] = []
        #expect(throws: InputFailure.inputPaused([.destinationNotPrepared])) {
            _ = try UserFocusRestorer.requestFront(
                processID: 101,
                windowNumber: 801,
                consumerProcessID: 101,
                requestLocal: { calls.append("local \($0)"); return false },
                requestRemote: { calls.append("remote"); return 0 }
            )
        }
        #expect(calls == ["local 801"])
    }

    @Test("External destinations retain one remote request", arguments: [Int32(202), Int32(303)])
    func remoteRequest(processID: Int32) throws {
        var calls: [String] = []
        let code = try UserFocusRestorer.requestFront(
            processID: processID,
            windowNumber: 801,
            consumerProcessID: 101,
            requestLocal: { calls.append("local \($0)"); return true },
            requestRemote: { calls.append("remote"); return -50 }
        )
        #expect(code == -50)
        #expect(calls == ["remote"])
    }
}
