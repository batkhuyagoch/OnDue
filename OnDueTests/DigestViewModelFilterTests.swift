import XCTest
@testable import OnDue

final class DigestViewModelFilterTests: XCTestCase {
    func testShippingDisabledKeepsDeliveryAction() {
        let prefs = DigestPrefs(includeShipping: false)
        let item = makeItem(
            title: "Delivery attempt failed",
            reasonCode: .deliveryActionRequired,
            primaryHypothesisId: ObligationHypothesis.deliveryRequired.rawValue
        )

        XCTAssertTrue(DigestViewModel.shouldIncludeForDigest(item, preferences: prefs))
    }

    func testShippingDisabledRemovesPassiveShippingUpdate() {
        let prefs = DigestPrefs(includeShipping: false)
        let item = makeItem(
            title: "Your package was delivered",
            reasonCode: .receiptConfirmation,
            matchedReasons: ["Package delivered confirmation"]
        )

        XCTAssertFalse(DigestViewModel.shouldIncludeForDigest(item, preferences: prefs))
    }

    func testMarketingDisabledRemovesMarketingReasonCode() {
        let prefs = DigestPrefs(includeMarketing: false)
        let item = makeItem(
            title: "Big sale this week",
            reasonCode: .marketingPromo,
            primaryHypothesisId: ObligationHypothesis.marketingNoise.rawValue
        )

        XCTAssertFalse(DigestViewModel.shouldIncludeForDigest(item, preferences: prefs))
    }

    func testSecurityDisabledRemovesSecurityInformational() {
        let prefs = DigestPrefs(includeSecurityAlerts: false)
        let item = makeItem(
            title: "Sign-in attempt detected",
            reasonCode: .securityInformational
        )

        XCTAssertFalse(DigestViewModel.shouldIncludeForDigest(item, preferences: prefs))
    }

    func testNonMarketingItemRemainsWhenMarketingDisabled() {
        let prefs = DigestPrefs(includeMarketing: false)
        let item = makeItem(
            title: "Please upload your updated document",
            reasonCode: .accountVerification,
            primaryHypothesisId: ObligationHypothesis.identityVerification.rawValue
        )

        XCTAssertTrue(DigestViewModel.shouldIncludeForDigest(item, preferences: prefs))
    }

    private func makeItem(
        title: String,
        reasonCode: ReasonCode,
        primaryHypothesisId: String? = nil,
        matchedReasons: [String] = [],
        matchedRuleIds: [String] = []
    ) -> ObligationItem {
        ObligationItem(
            id: UUID().uuidString,
            mailboxAccountId: "acct",
            messagePk: 1,
            title: title,
            deadline: nil,
            status: .open,
            category: .other,
            risk: .medium,
            whoOwes: .me,
            confidence: 0.8,
            evidenceQuote: "",
            matchedRuleIds: matchedRuleIds,
            matchedSignalTypes: [],
            matchedReasons: matchedReasons,
            primaryHypothesisId: primaryHypothesisId,
            reasonCode: reasonCode,
            policyVersion: DecisionPolicyVersion.v2PolicyDriven.rawValue,
            snoozedUntil: nil,
            repeatCount: 1,
            lastSeenAt: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

private final class DigestPrefs: FilterPreferencesStoring {
    var includeSecurityAlerts: Bool
    var includeStatements: Bool
    var includeMarketing: Bool
    var includeNewsletters: Bool
    var includeShipping: Bool

    init(
        includeSecurityAlerts: Bool = true,
        includeStatements: Bool = true,
        includeMarketing: Bool = true,
        includeNewsletters: Bool = true,
        includeShipping: Bool = true
    ) {
        self.includeSecurityAlerts = includeSecurityAlerts
        self.includeStatements = includeStatements
        self.includeMarketing = includeMarketing
        self.includeNewsletters = includeNewsletters
        self.includeShipping = includeShipping
    }
}
