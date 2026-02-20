import XCTest
@testable import OnDue

final class PolicyValidatorTests: XCTestCase {
    func testEveryHypothesisHasDecisionSemanticsOrExplicitNonDrivingRole() {
        let policy = DecisionPolicy(version: .v2PolicyDriven)
        let nonDriving: Set<ObligationHypothesis> = [.marketingNoise]
        let uncovered = policy.allHypotheses.subtracting(policy.drivingHypotheses).subtracting(nonDriving)
        XCTAssertTrue(uncovered.isEmpty, "Unmapped hypotheses: \(uncovered)")
    }

    func testReasonCatalogCoversAllReasonCodes() {
        for code in ReasonCode.allCases {
            XCTAssertFalse(ReasonCatalog.displayText(for: code).isEmpty)
            XCTAssertFalse(ReasonCatalog.shortChipText(for: code).isEmpty)
        }
    }

    func testLabelReasonOptionsStayInSyncWithReasonCodes() {
        let options = Set(ReasonCatalog.labelingOptions)
        for code in ReasonCode.allCases {
            XCTAssertTrue(options.contains(ReasonCatalog.displayText(for: code)))
        }
    }

    func testObligationCanonicalDecisionInvariantsRequirePolicyFields() {
        var record = ObligationRecord(
            mailboxAccountId: "acct",
            messagePk: 1,
            category: .request,
            title: "title",
            evidenceQuote: "evidence",
            obligationKey: "key",
            primaryHypothesisId: ObligationHypothesis.userActionRequired.rawValue,
            reasonCode: ReasonCode.directRequestWithoutDeadline.rawValue,
            policyVersion: DecisionPolicyVersion.v2PolicyDriven.rawValue
        )
        XCTAssertNoThrow(try record.validateCanonicalDecisionInvariants())

        record.policyVersion = nil
        XCTAssertThrowsError(try record.validateCanonicalDecisionInvariants())
    }
}
