import ChatCore
import FileConversations
import Foundation
import Testing

@Suite("Saved chat conversations")
struct ConversationTests {
    @Test
    func roundTripAndExclusiveLease() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mecum-history-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ConversationStore(directory: directory)
        var original = Conversation(provider: .claude, model: "sonnet")
        original.providerSessionID = "provider-reference"
        original.append(.user, "Remember this conversation.")
        original.append(.tool, "honest_miss")
        try store.save(original)
        let read = try store.load(original.id)
        #expect(read.providerSessionID == original.providerSessionID)
        #expect(read.entries.map(\.text) == original.entries.map(\.text))
        #expect(try store.list().map(\.id) == [original.id])
        let lease = try store.lease(original.id)
        _ = withExtendedLifetime(lease) {
            #expect(throws: (any Error).self) { _ = try store.lease(original.id) }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("\(original.id.uuidString).json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func corruptHistoryIsReportedRatherThanSilentlyDiscarded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mecum-corrupt-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ConversationStore(directory: directory)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("\(UUID().uuidString).json"))
        #expect(throws: (any Error).self) { _ = try store.list() }
    }
}
