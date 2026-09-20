import EngineCore

/// BatchSequence executes in order, once per step, stopping on any unverified or failed outcome.
/// Its caller owns the shared Seat and cleanup. Earlier effects are never rolled back or replayed.
enum BatchSequence {

    static func run(
        _ steps: [BatchStep],
        perform: (Int, BatchStep) async throws -> ActOutcomeKind
    ) async throws {
        for (index, step) in steps.enumerated() {
            do {
                try Task.checkCancellation()
                let kind = try await perform(index + 1, step)
                guard step.accepts(kind) else { throw ActFailure(kind) }
            } catch {
                throw BatchFailure(step: index + 1, total: steps.count, cause: error)
            }
        }
    }
}

/// BatchFailure preserves the failed step and cause; previous steps may already have taken effect.
struct BatchFailure: Error, CustomStringConvertible {
    let step: Int
    let total: Int
    let cause: any Error

    var description: String {
        "batch stopped at step \(step)/\(total): \(cause). Later steps were not run; earlier effects remain."
    }
}
