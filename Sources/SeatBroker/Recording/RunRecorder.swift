import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Appends one JSON line per run to `runs.jsonl` and saves the final frame as
/// PNG next to it. Reads the whole file back for the history view; the lab
/// will not produce enough runs for that to matter.
struct RunRecorder: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var logURL: URL { directory.appendingPathComponent("runs.jsonl") }

    /// Writes the frame first so the record can name the file.
    func saveFrame(_ image: CGImage, runID: UUID) -> String? {
        let name = "\(runID.uuidString).png"
        guard let destination = CGImageDestinationCreateWithURL(
            directory.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? name : nil
    }

    func append(_ record: RunRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(record) else { return }
        line.append(10)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: logURL)
        }
    }

    /// Newest first. A line that no longer decodes is skipped, not fatal.
    func load() -> [RunRecord] {
        guard let data = try? Data(contentsOf: logURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 10)
            .compactMap { try? decoder.decode(RunRecord.self, from: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func frameURL(for record: RunRecord) -> URL? {
        record.finalFrameFile.map { directory.appendingPathComponent($0) }
    }
}
