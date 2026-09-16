//
//  IdentityAllocationAssessment.swift
//  AgentSeatKit
//

/// The proof required before the identity sample can claim that its own code
/// allocated nothing. The SDK control performs the same two `GetProcessPID`
/// mappings as one guarded identity read; subtraction is valid only when both
/// samples cover the same number of calls and every mapping answered correctly.
nonisolated struct IdentityAllocationAssessment: Equatable {

    nonisolated enum Invalid: Error, Equatable {
        case missingIdentitySample
        case missingControlSample
        case invalidIterations(identity: Int, control: Int)
        case incompleteIdentityReads(expected: Int, observed: Int)
        case failedIdentityReads(Int)
        case incompleteMappings(expected: Int, observed: Int)
        case failedMappings(Int)
        case controlExceedsIdentity(identity: UInt64, control: UInt64)

        var message: String {
            switch self {
            case .missingIdentitySample:
                "the raw identity sample is missing"
            case .missingControlSample:
                "the two-call GetProcessPID control sample is missing"
            case .invalidIterations(let identity, let control):
                "identity/control iteration counts are invalid or unequal (\(identity)/\(control))"
            case .incompleteIdentityReads(let expected, let observed):
                "the identity sample ran \(observed) reads; expected \(expected)"
            case .failedIdentityReads(let count):
                "\(count) identity read(s) failed or returned the wrong target identity"
            case .incompleteMappings(let expected, let observed):
                "the PID control ran \(observed) mappings; expected \(expected)"
            case .failedMappings(let count):
                "\(count) PID control mapping(s) failed or returned the wrong target PID"
            case .controlExceedsIdentity(let identity, let control):
                "the PID control allocated \(control), more than raw identity's \(identity)"
            }
        }
    }

    let identityAllocations: UInt64
    let controlAllocations : UInt64
    let residualAllocations: UInt64
    let iterations         : Int

    var identityAllocationsPerCall: Double {
        Double(identityAllocations) / Double(iterations)
    }

    var controlAllocationsPerCall: Double {
        Double(controlAllocations) / Double(iterations)
    }

    var residualAllocationsPerCall: Double {
        Double(residualAllocations) / Double(iterations)
    }

    static func evaluate(
        identityAllocations: UInt64?,
        identityIterations : Int,
        controlAllocations : UInt64?,
        controlIterations  : Int,
        expectedIdentityReads: Int,
        observedIdentityReads: Int,
        failedIdentityReads  : Int,
        expectedMappings   : Int,
        observedMappings   : Int,
        failedMappings     : Int
    ) -> Result<Self, Invalid> {

        guard let identityAllocations else { return .failure(.missingIdentitySample) }
        guard let controlAllocations else { return .failure(.missingControlSample) }
        guard identityIterations > 0, identityIterations == controlIterations else {
            return .failure(.invalidIterations(
                identity: identityIterations,
                control : controlIterations
            ))
        }
        guard observedIdentityReads == expectedIdentityReads else {
            return .failure(.incompleteIdentityReads(
                expected: expectedIdentityReads,
                observed: observedIdentityReads
            ))
        }
        guard failedIdentityReads == 0 else {
            return .failure(.failedIdentityReads(failedIdentityReads))
        }
        guard observedMappings == expectedMappings else {
            return .failure(.incompleteMappings(
                expected: expectedMappings,
                observed: observedMappings
            ))
        }
        guard failedMappings == 0 else { return .failure(.failedMappings(failedMappings)) }
        guard controlAllocations <= identityAllocations else {
            return .failure(.controlExceedsIdentity(
                identity: identityAllocations,
                control : controlAllocations
            ))
        }

        return .success(Self(
            identityAllocations: identityAllocations,
            controlAllocations : controlAllocations,
            residualAllocations: identityAllocations - controlAllocations,
            iterations         : identityIterations
        ))
    }
}
