import Foundation

/// SWEEPING A PROVISIONAL NUMBER INTO A MEASURED ONE — and then refusing to move it again.
///
/// Roughly twenty numbers across the generic-core map are invented: settle's K and cap, restless
/// 8-of-10, the 15% perpetually-animated floor, the pull budgets (`section` and `since` have never
/// been measured at all), the Look thresholds 12/150/30/300, the identity Jaccard 0.60. Each was
/// written down *to be falsified*. This is the falsifier.
///
/// The whole thing rests on one asymmetry: **offline we know the future.** A trace runs past the
/// decision, so "was settle declared before the last real change" is answerable in replay and
/// unanswerable live. That is why ADR 0006's four numbers can be earned without the detector ever
/// having to tell "it started" from "it finished" — the thing it is forbidden to attempt.
public enum SweepScore: String, Codable, Sendable {
    /// Lower is better (early-settle rate, never-fired rate, wrong-drop rate).
    case minimise
    /// Higher is better (separation between a positive and a negative class).
    case maximise
}

public struct SweepPoint: Codable, Sendable, Equatable {
    public let value: Double          // the parameter setting
    public let score: Double          // what it scored
    public let n: Int                 // sample size behind that score
    public init(value: Double, score: Double, n: Int) { self.value = value; self.score = score; self.n = n }
}

public struct SweepResult: Codable, Sendable, Equatable {
    public let parameter: String
    public let direction: SweepScore
    public let points: [SweepPoint]
    public let corpus: [String]       // take ids — provenance, so a frozen number can be re-derived
    public init(parameter: String, direction: SweepScore, points: [SweepPoint], corpus: [String]) {
        self.parameter = parameter; self.direction = direction; self.points = points; self.corpus = corpus
    }

    /// THE KNEE — the last setting that still buys a real improvement. Not the optimum: the optimum of
    /// a minimised score is always the extreme setting (K=4 never settles early because it barely
    /// settles), and taking it would be how "measured" quietly becomes "degenerate".
    ///
    /// Defined as the point after which the marginal gain falls below `marginalFloor` of the total
    /// range swept. Nil when the curve is flat — a parameter that changes nothing has no knee, and
    /// saying so is more useful than inventing one.
    public func knee(marginalFloor: Double = 0.10) -> SweepPoint? {
        let sorted = points.sorted { $0.value < $1.value }
        guard sorted.count >= 3 else { return nil }
        let scores = sorted.map(\.score)
        let range = (scores.max() ?? 0) - (scores.min() ?? 0)
        guard range > 0 else { return nil }
        var best = sorted[0]
        for i in 1..<sorted.count {
            let gain = direction == .minimise ? (sorted[i-1].score - sorted[i].score)
                                              : (sorted[i].score - sorted[i-1].score)
            if gain / range < marginalFloor { break }
            best = sorted[i]
        }
        return best
    }
}

/// A number that has stopped being provisional.
public struct FrozenValue: Codable, Sendable, Equatable {
    public let parameter: String
    public let value: Double
    public let frozenAt: Date
    public let derivation: String     // "knee of K sweep over 4 takes" / "p95 x 1.2 at baseline"
    public let corpus: [String]
    public let corpusSize: Int        // what "the corpus grows" is measured against
    public init(parameter: String, value: Double, frozenAt: Date = Date(), derivation: String,
                corpus: [String], corpusSize: Int) {
        self.parameter = parameter; self.value = value; self.frozenAt = frozenAt
        self.derivation = derivation; self.corpus = corpus; self.corpusSize = corpusSize
    }
}

/// THE FREEZE RULE (ADR 0011), implemented as a REFUSAL rather than a convention.
///
/// A frozen number is re-derived when the corpus grows or the rule is falsified — **never because a
/// change would otherwise fail.** Without that last clause "re-derive from the harness" degenerates
/// into "tune until green", and every measured number in the effort becomes decoration. The refusal
/// is the feature; a warning would be something a tired person clicks past at 2am.
public struct FreezeLedger: Codable, Sendable {

    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case alreadyFrozen(parameter: String, at: Date, value: Double, corpusSize: Int)
        case noKnee(parameter: String)
        public var description: String {
            switch self {
            case let .alreadyFrozen(p, at, v, n):
                return "\(p) was frozen at \(v) on \(at) over a corpus of \(n) — re-derive only when the corpus GROWS or the rule is falsified, never because a change would otherwise fail (ADR 0011)"
            case let .noKnee(p):
                return "\(p) has no knee: the curve is flat over the swept range, so the sweep did not earn a value"
            }
        }
    }

    public private(set) var frozen: [String: FrozenValue]
    public init(frozen: [String: FrozenValue] = [:]) { self.frozen = frozen }

    /// Freeze from a sweep's knee. Refuses if the parameter is already frozen and the corpus has not
    /// grown since.
    public mutating func freeze(from sweep: SweepResult, corpusSize: Int, marginalFloor: Double = 0.10) throws -> FrozenValue {
        if let existing = frozen[sweep.parameter], corpusSize <= existing.corpusSize {
            throw Refusal.alreadyFrozen(parameter: sweep.parameter, at: existing.frozenAt,
                                        value: existing.value, corpusSize: existing.corpusSize)
        }
        guard let knee = sweep.knee(marginalFloor: marginalFloor) else { throw Refusal.noKnee(parameter: sweep.parameter) }
        let v = FrozenValue(parameter: sweep.parameter, value: knee.value,
                            derivation: "knee of \(sweep.parameter) sweep over \(sweep.corpus.count) take(s)",
                            corpus: sweep.corpus, corpusSize: corpusSize)
        frozen[sweep.parameter] = v
        return v
    }

    /// Freeze a BUDGET from a baseline measurement: `p95 × 1.2` (ADR 0011). Same refusal.
    public mutating func freezeBudget(parameter: String, baselineP95: Double, corpus: [String], corpusSize: Int) throws -> FrozenValue {
        if let existing = frozen[parameter], corpusSize <= existing.corpusSize {
            throw Refusal.alreadyFrozen(parameter: parameter, at: existing.frozenAt,
                                        value: existing.value, corpusSize: existing.corpusSize)
        }
        let v = FrozenValue(parameter: parameter, value: baselineP95 * 1.2,
                            derivation: "p95 x 1.2 at baseline (p95 = \(baselineP95))",
                            corpus: corpus, corpusSize: corpusSize)
        frozen[parameter] = v
        return v
    }

    /// The falsification door: an explicit, recorded reason. Deliberately not callable by accident —
    /// it takes a written justification, because "the rule was falsified" is a claim someone has to make.
    public mutating func retract(parameter: String, becauseRuleFalsified reason: String) -> Bool {
        guard reason.count >= 20, frozen[parameter] != nil else { return false }
        frozen.removeValue(forKey: parameter)
        return true
    }
}
