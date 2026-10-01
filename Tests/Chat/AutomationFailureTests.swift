import AutomationRuntime
import Foundation
import Testing

struct AutomationFailureTests {
    @Test func localizedErrorKeepsTheReasonUsedByTheAppRecorder() {
        let reason = "Mecum stopped after 3 unsuccessful automation attempts without a verified result."
        let error: any Error = AutomationFailure(reason)
        #expect(error.localizedDescription == reason)
    }
}
