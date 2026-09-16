//
//  IdentityAllocationAssessmentTests.swift
//  AgentSeatKit
//

@main
struct IdentityAllocationAssessmentTests {

    static func main() {
        expectSuccess(raw: 2_800, control: 2_800, residual: 0)
        expectSuccess(raw: 2_803, control: 2_800, residual: 3)

        expectFailure(.missingIdentitySample, identityAllocations: nil)
        expectFailure(.missingControlSample, controlAllocations: nil)
        expectFailure(.invalidIterations(identity: 200, control: 199), controlIterations: 199)
        expectFailure(
            .incompleteIdentityReads(expected: 250, observed: 249),
            observedIdentityReads: 249
        )
        expectFailure(.failedIdentityReads(1), failedIdentityReads: 1)
        expectFailure(.incompleteMappings(expected: 500, observed: 499), observedMappings: 499)
        expectFailure(.failedMappings(1), failedMappings: 1)
        expectFailure(
            .controlExceedsIdentity(identity: 2_799, control: 2_800),
            identityAllocations: 2_799
        )

        print("identity allocation assessment: 10 checks passed")
    }

    private static func expectSuccess(raw: UInt64, control: UInt64, residual: UInt64) {
        let result = evaluate(
            identityAllocations: raw,
            controlAllocations : control
        )
        guard case .success(let assessment) = result,
              assessment.residualAllocations == residual
        else { fatalError("expected residual \(residual), got \(result)") }
    }

    private static func expectFailure(
        _ expected             : IdentityAllocationAssessment.Invalid,
        identityAllocations    : UInt64? = 2_800,
        identityIterations     : Int = 200,
        controlAllocations     : UInt64? = 2_800,
        controlIterations      : Int = 200,
        expectedIdentityReads  : Int = 250,
        observedIdentityReads  : Int = 250,
        failedIdentityReads    : Int = 0,
        expectedMappings       : Int = 500,
        observedMappings       : Int = 500,
        failedMappings         : Int = 0
    ) {
        let result = IdentityAllocationAssessment.evaluate(
            identityAllocations: identityAllocations,
            identityIterations : identityIterations,
            controlAllocations : controlAllocations,
            controlIterations  : controlIterations,
            expectedIdentityReads: expectedIdentityReads,
            observedIdentityReads: observedIdentityReads,
            failedIdentityReads  : failedIdentityReads,
            expectedMappings   : expectedMappings,
            observedMappings   : observedMappings,
            failedMappings     : failedMappings
        )
        guard case .failure(let invalid) = result, invalid == expected else {
            fatalError("expected \(expected), got \(result)")
        }
    }

    private static func evaluate(
        identityAllocations: UInt64,
        controlAllocations : UInt64
    ) -> Result<IdentityAllocationAssessment, IdentityAllocationAssessment.Invalid> {
        IdentityAllocationAssessment.evaluate(
            identityAllocations: identityAllocations,
            identityIterations : 200,
            controlAllocations : controlAllocations,
            controlIterations  : 200,
            expectedIdentityReads: 250,
            observedIdentityReads: 250,
            failedIdentityReads  : 0,
            expectedMappings   : 500,
            observedMappings   : 500,
            failedMappings     : 0
        )
    }
}
