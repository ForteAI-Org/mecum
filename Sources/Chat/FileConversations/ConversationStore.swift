import ChatCore
import Darwin
import Foundation

/// ConversationStore owns atomic JSON transcripts. The caller leases a conversation for its chat lifetime.
public struct ConversationStore: Sendable {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    public func list() throws -> [Conversation] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(Conversation.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func load(_ id: UUID) throws -> Conversation {
        try JSONDecoder().decode(Conversation.self, from: Data(contentsOf: file(id)))
    }

    public func save(_ conversation: Conversation) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(conversation).write(to: file(conversation.id), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(conversation.id).path)
    }

    public func lease(_ id: UUID) throws -> ConversationLease {
        try ConversationLease(path: directory.appendingPathComponent("\(id.uuidString).lock").path)
    }

    private func file(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
}

/// ConversationLease excludes concurrent writers. Closing its descriptor, including at exit, releases the lock.
public final class ConversationLease {
    private let descriptor: Int32

    init(path: String) throws {
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw NSError(domain: "MecumChat", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "This conversation is already open in another terminal."])
        }
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }
}
