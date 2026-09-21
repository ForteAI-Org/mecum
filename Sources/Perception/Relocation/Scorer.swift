import Foundation
import LocatorCore

/// Per-candidate features the stage-4 scorer consumes. The `Relocator` computes these from CV/OCR/
/// geometry; the `Scorer` only does the weighted math + the accept/ambiguity gate, so it's pure and
/// fully unit-testable with injected values.
public struct CandidateFeatures: Sendable, Equatable {
    public var visualNCC: Double            // max NCC over state-variant crops (raw, may be < 0)
    public var elementHasText: Bool
    public var textExactMatch: Bool
    public var textFuzzyRatio: Double       // 0…1 best fuzzy match when not exact
    public var neighborFraction: Double     // 0…1 fraction of text neighbors found at expected offset
    public var positionDistanceFraction: Double  // normalized distance from expected window-relative pos
    public var classMatches: Bool
    public var sizeRatio: Double            // candidate size / expected size (1.0 == exact)

    public init(
        visualNCC: Double,
        elementHasText: Bool,
        textExactMatch: Bool = false,
        textFuzzyRatio: Double = 0,
        neighborFraction: Double = 0,
        positionDistanceFraction: Double = 0,
        classMatches: Bool = false,
        sizeRatio: Double = 1.0
    ) {
        self.visualNCC = visualNCC
        self.elementHasText = elementHasText
        self.textExactMatch = textExactMatch
        self.textFuzzyRatio = textFuzzyRatio
        self.neighborFraction = neighborFraction
        self.positionDistanceFraction = positionDistanceFraction
        self.classMatches = classMatches
        self.sizeRatio = sizeRatio
    }
}

/// The outcome of scoring a candidate set.
public struct ScoreDecision: Sendable, Equatable {
    public var accepted: Bool
    public var bestIndex: Int?
    public var best: Double
    public var secondBest: Double?
}

/// Stage-4 scorer: `0.30·visual + 0.25·text + 0.20·neighbors + 0.15·geometry + 0.10·class·size`,
/// accepted iff `best ≥ stage4ScoreFloor` AND `best − second ≥ ambiguityMargin`. Two near-tied
/// candidates (e.g. 0.65 / 0.64) **fail loudly** rather than guessing.
public struct Scorer: Sendable {
    public let tuning: RelocationTuning
    public let thresholds: Thresholds
    /// Sum of the five weights, used to normalize the score into [0,1] even if a tuning-loop misconfig
    /// leaves the weights un-normalized — so the fixed 0.62 floor / 0.10 margin stay calibrated.
    private let weightSum: Double

    public init(tuning: RelocationTuning = .defaults, thresholds: Thresholds = .defaults) {
        self.tuning = tuning
        self.thresholds = thresholds
        let sum = tuning.weightVisual + tuning.weightText + tuning.weightNeighbors
            + tuning.weightGeometry + tuning.weightClassSize
        self.weightSum = sum > 0 ? sum : 1
    }

    // MARK: Sub-scores (each in 0…1)

    /// NCC mapped [nccMin…1] → [0…1]; hard 0 below `nccMin·0.9`.
    func visualSubScore(ncc: Double) -> Double {
        if ncc < thresholds.nccMin * 0.9 { return 0 }
        let mapped = (ncc - thresholds.nccMin) / (1 - thresholds.nccMin)
        return min(1, max(0, mapped))
    }

    func textSubScore(hasText: Bool, exact: Bool, fuzzy: Double) -> Double {
        guard hasText else { return tuning.noTextScoreFloor }
        return exact ? 1 : min(1, max(0, fuzzy))
    }

    /// Gaussian falloff on the normalized distance from the expected window-relative position.
    func geometrySubScore(distanceFraction d: Double) -> Double {
        let sigma = tuning.geometrySigmaFraction
        guard sigma > 0 else { return d == 0 ? 1 : 0 }
        return exp(-(d * d) / (2 * sigma * sigma))
    }

    func classSizeSubScore(classMatches: Bool, sizeRatio: Double) -> Double {
        let classPart = classMatches ? 0.5 : 0.0
        let sizePart = abs(sizeRatio - 1) <= tuning.sizeTolerance ? 0.5 : 0.0
        return classPart + sizePart
    }

    // MARK: Weighted score + gate

    public func score(_ f: CandidateFeatures) -> Double {
        let weighted = tuning.weightVisual * visualSubScore(ncc: f.visualNCC)
            + tuning.weightText * textSubScore(hasText: f.elementHasText, exact: f.textExactMatch, fuzzy: f.textFuzzyRatio)
            + tuning.weightNeighbors * min(1, max(0, f.neighborFraction))
            + tuning.weightGeometry * geometrySubScore(distanceFraction: f.positionDistanceFraction)
            + tuning.weightClassSize * classSizeSubScore(classMatches: f.classMatches, sizeRatio: f.sizeRatio)
        return weighted / weightSum   // normalized → always in [0,1] regardless of weight config
    }

    /// Apply the accept/ambiguity gate to a set of raw scores.
    public func decide(scores: [Double]) -> ScoreDecision {
        guard !scores.isEmpty else {
            return ScoreDecision(accepted: false, bestIndex: nil, best: 0, secondBest: nil)
        }
        let sorted = scores.sorted(by: >)
        let best = sorted[0]
        // The runner-up is the next score in rank order — INCLUDING a tied top, which must read as
        // ambiguous (margin 0). Taking the next strictly-smaller value would hide a two-way tie.
        let secondBest: Double? = scores.count >= 2 ? sorted[1] : nil
        let bestIndex = scores.firstIndex(of: best)
        let marginOK = secondBest.map { best - $0 >= thresholds.ambiguityMargin } ?? true
        let accepted = best >= thresholds.stage4ScoreFloor && marginOK
        return ScoreDecision(accepted: accepted, bestIndex: accepted ? bestIndex : nil, best: best, secondBest: secondBest)
    }

    public func evaluate(_ candidates: [CandidateFeatures]) -> ScoreDecision {
        decide(scores: candidates.map(score))
    }
}
