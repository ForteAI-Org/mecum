import Foundation

/// On-disk store for flows: one `<sanitized-name>.json` per flow, written atomically. The original
/// name is kept inside the JSON; lookups sanitize the name to the filename.
public struct FlowStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    private func url(forName name: String) -> URL {
        directory.appendingPathComponent("\(Self.sanitize(name)).json")
    }

    /// Filename-safe form of a flow name (`[A-Za-z0-9._-]`, others → `_`).
    public static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let mapped = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return mapped.isEmpty ? "flow" : mapped
    }

    public func save(_ flow: Flow) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try DescriptorStore.makeEncoder().encode(flow)
        try data.write(to: url(forName: flow.name), options: [.atomic])
    }

    public func load(name: String) throws -> Flow {
        let u = url(forName: name)
        guard let data = try? Data(contentsOf: u) else { throw FlowError.notFound(name) }
        return try DescriptorStore.makeDecoder().decode(Flow.self, from: data)
    }

    /// Names of all stored flows, sorted.
    public func list() throws -> [Flow] {
        let fm = FileManager.default
        let entries: [URL]
        do { entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch CocoaError.fileReadNoSuchFile { return [] }
        let dec = DescriptorStore.makeDecoder()
        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? dec.decode(Flow.self, from: $0) } }
            .sorted { $0.name < $1.name }
    }

    public func delete(name: String) throws {
        try? FileManager.default.removeItem(at: url(forName: name))
    }
}

public enum FlowError: Error, Equatable {
    case notFound(String)
}
