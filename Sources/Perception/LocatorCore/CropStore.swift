import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum CropError: Error, Equatable {
    case encodeFailed(String)
    case decodeFailed(String)
    case invalidName(String)
}

/// Reads/writes element crop PNGs alongside descriptors. The naming convention lives here so that
/// ``VisualDescriptor`` only ever stores bare filenames (`cropRef`), never paths.
///
/// Uses ImageIO directly (no AppKit/`NSImage`) so `LocatorCore` stays headless-usable.
public struct CropStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: Naming convention

    /// `<uuid>.<state>.png` (e.g. `<uuid>.default.png`, `<uuid>.on.png`).
    ///
    /// `state` is sanitized: state names come from AX values / UI labels and can contain path-significant
    /// characters (`/`, `:`, …). Anything outside `[A-Za-z0-9_-]` is mapped to `_` so the result is always
    /// a safe bare filename, upholding the `cropRef` invariant.
    public static func cropName(id: UUID, state: String = "default") -> String { "\(id.uuidString).\(sanitize(state)).png" }
    /// `<uuid>.context.png`.
    public static func contextCropName(id: UUID) -> String { "\(id.uuidString).context.png" }

    private static let stateAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    private static func sanitize(_ state: String) -> String {
        let mapped = String(state.unicodeScalars.map { stateAllowed.contains($0) ? Character($0) : "_" })
        return mapped.isEmpty ? "state" : mapped
    }

    // MARK: I/O

    /// Atomically write a `CGImage` as PNG under `name` (a bare filename, no path separators).
    public func writePNG(_ image: CGImage, name: String) throws {
        // A bad name is a recoverable error, not a reason to abort the process.
        guard !name.contains("/") else { throw CropError.invalidName(name) }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CropError.encodeFailed(name)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CropError.encodeFailed(name) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (data as Data).write(to: directory.appendingPathComponent(name), options: [.atomic])
    }

    public func readPNG(name: String) throws -> CGImage {
        let url = directory.appendingPathComponent(name)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw CropError.decodeFailed(name)
        }
        return image
    }

    /// Bare filenames of all crops belonging to a descriptor id.
    public func crops(forDescriptorID id: UUID) throws -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .map { $0.lastPathComponent }
            .filter { $0.hasPrefix("\(id.uuidString).") && $0.hasSuffix(".png") }
            .sorted()
    }
}
