import Darwin
import Foundation

/// MCPConnectionDirectory owns one app's local endpoint directory. Its process lease prevents a
/// second app instance from replacing live credentials. Endpoints are private, atomic and revocable.
@MainActor
public final class MCPConnectionDirectory {
    public let url: URL
    private var lock: Int32 = -1

    public init(url: URL) { self.url = url }
    isolated deinit { if lock >= 0 { Darwin.close(lock) } }

    public func acquire() throws {
        guard lock < 0 else { return }
        let files = FileManager.default
        try files.createDirectory(at: url, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let fd = Darwin.open(url.appendingPathComponent("host.lock").path,
                             O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw CocoaError(.fileLocking)
        }
        lock = fd
    }

    public func endpoint(for id: UUID) -> URL { url.appendingPathComponent(id.uuidString + ".connection.json") }

    public func publish(_ connection: LocalConnection, for id: UUID) throws {
        guard lock >= 0 else { throw CocoaError(.fileLocking) }
        try JSONEncoder().encode(connection).write(to: endpoint(for: id), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: endpoint(for: id).path)
    }

    public func remove(_ id: UUID) throws {
        guard lock >= 0 else { throw CocoaError(.fileLocking) }
        let file = endpoint(for: id)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    public func release() {
        if lock >= 0 { Darwin.close(lock); lock = -1 }
    }
}
