import Foundation

/// MCPClientStore persists grants, never connection credentials or tool arguments.
/// Its caller holds MCPConnectionDirectory's process lease across every read-modify-write.
@MainActor
struct MCPClientStore {
    let directory: URL
    private var file: URL { directory.appendingPathComponent("clients.json") }

    func load() throws -> [MCPClientProfile] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        guard data.count <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
        let profiles = try JSONDecoder().decode([MCPClientProfile].self, from: data)
        guard profiles.count <= 16, Set(profiles.map(\.id)).count == profiles.count,
              profiles.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 80 }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return profiles
    }

    func save(_ profiles: [MCPClientProfile]) throws {
        try JSONEncoder().encode(profiles).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
