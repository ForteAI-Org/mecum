import Foundation

/// Per-descriptor acceptance thresholds for the relocation cascade. Persisted with each descriptor
/// so individual elements can be tuned, and so the defaults travel with old files.
public struct Thresholds: Codable, Equatable, Sendable {
    public var nccMin: Double               // default 0.85
    public var edgeHashMaxDist: Int         // default 10 (Hamming)
    public var stage4ScoreFloor: Double     // default 0.62
    public var ambiguityMargin: Double      // default 0.10 (best − second_best must exceed this)

    public init(nccMin: Double = 0.85, edgeHashMaxDist: Int = 10, stage4ScoreFloor: Double = 0.62, ambiguityMargin: Double = 0.10) {
        self.nccMin = nccMin
        self.edgeHashMaxDist = edgeHashMaxDist
        self.stage4ScoreFloor = stage4ScoreFloor
        self.ambiguityMargin = ambiguityMargin
    }

    public static let defaults = Thresholds()

    // Forward-compatible decode: any missing key falls back to its spec default, so a descriptor
    // written with a partial (or future-trimmed) thresholds object still loads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.nccMin = try c.decodeIfPresent(Double.self, forKey: .nccMin) ?? 0.85
        self.edgeHashMaxDist = try c.decodeIfPresent(Int.self, forKey: .edgeHashMaxDist) ?? 10
        self.stage4ScoreFloor = try c.decodeIfPresent(Double.self, forKey: .stage4ScoreFloor) ?? 0.62
        self.ambiguityMargin = try c.decodeIfPresent(Double.self, forKey: .ambiguityMargin) ?? 0.10
    }
}
