import XCTest
@testable import OnDue

final class RuleEngineTests: XCTestCase {
    private var engine: RuleEngine!

    override func setUp() {
        super.setUp()
        engine = RuleEngine(preferences: TestPreferences())
    }

    func testPaymentDueIsDetected() {
        let result = engine.evaluate(email: SampleEmails.paymentDue())
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.category, .payment)
        XCTAssertEqual(result?.decision, .accept)
    }

    func testAppointmentIsDetected() {
        let result = engine.evaluate(email: SampleEmails.appointmentInvite())
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.category, .appointment)
    }

    func testDocumentRequestIsDetected() {
        let result = engine.evaluate(email: SampleEmails.documentRequest())
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.category, .document)
    }

    func testMarketingPromoIsFiltered() {
        let result = engine.evaluate(email: SampleEmails.marketingPromo())
        XCTAssertNil(result)
    }

    func testUnsubscribeVetoesAction() {
        let result = engine.evaluate(email: SampleEmails.actionRequiredWithUnsubscribe())
        XCTAssertNil(result)
    }

    func testSecurityAlertIsRejected() {
        let result = engine.evaluate(email: SampleEmails.securityAlert())
        XCTAssertNil(result)
    }

    func testReceiptIsRejected() {
        let result = engine.evaluate(email: SampleEmails.receiptEmail())
        XCTAssertNil(result)
    }

    func testDateOnlyInfoIsRejected() {
        let result = engine.evaluate(email: SampleEmails.dateOnlyInfo())
        XCTAssertNil(result)
    }

    func testPromoUrgencyIsRejected() {
        let result = engine.evaluate(email: SampleEmails.promoUrgency())
        XCTAssertNil(result)
    }

    func testRequiredEvidenceGating() {
        let email = SampleEmails.marketingPromo()
        let evaluation = engine.assess(email: email)
        XCTAssertEqual(evaluation.decision, .reject)
    }

    func testConfidenceSemantics() {
        let email = SampleEmails.paymentDue()
        let evaluation = engine.assess(email: email)
        XCTAssertEqual(evaluation.decision, .accept)
        XCTAssertGreaterThanOrEqual(evaluation.confidence, 0.7)
    }

    func testGoldDatasetExpectations() {
        var firedByHypothesis: [ObligationHypothesis: Int] = [:]
        var blockedCount = 0
        var needsReviewCount = 0

        for sample in GoldDataset.samples {
            let assessment = engine.assess(email: sample.email)
            XCTAssertEqual(assessment.decision, sample.expectedOutcome, sample.id)

            if assessment.decision == .needsReview {
                needsReviewCount += 1
            }
            if assessment.decision == .reject {
                blockedCount += 1
            }

            if let expected = sample.expectedHypothesis {
                let matched = assessment.matchedRuleIds.contains(expected.rawValue)
                XCTAssertTrue(matched, sample.id)
                firedByHypothesis[expected, default: 0] += 1
            }

            XCTAssertFalse(assessment.matchedReasons.contains(where: { reason in
                reason.contains("signal.") || reason.contains("rule_") || reason.contains("weight")
            }))
        }

        let total = GoldDataset.samples.count
        let needsReviewRatio = Double(needsReviewCount) / Double(max(total, 1))
        XCTAssertLessThanOrEqual(needsReviewRatio, 0.15)

        Logger.info("Hypothesis health summary: fired=\(firedByHypothesis) blocked=\(blockedCount) needsReview=\(needsReviewCount)")
    }

    func testUscisReceiptIsDetected() {
        let result = engine.evaluate(email: SampleEmails.uscisReceiptNotice())
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.category, .document)
    }

    func testUscisRFEIsDetectedInYearScan() {
        let result = engine.evaluateYearScan(email: SampleEmails.uscisRFE())
        XCTAssertNotNil(result)
    }

    func testCourtNoticeIsDetectedInYearScan() {
        let result = engine.evaluateYearScan(email: SampleEmails.courtNotice())
        XCTAssertNotNil(result)
    }

    func testIrsNoticeIsDetectedInYearScan() {
        let result = engine.evaluateYearScan(email: SampleEmails.irsNotice())
        XCTAssertNotNil(result)
    }

    func testStateAgencyNoticeIsDetected() {
        let result = engine.evaluate(email: SampleEmails.stateAgencyNotice())
        XCTAssertNotNil(result)
    }

    func testDateParsingFindsDeadline() {
        let date = DateParsing.parseDate(from: "Payment due March 15")
        XCTAssertNotNil(date)
    }
}

private struct TestPreferences: FilterPreferencesStoring {
    var includeSecurityAlerts: Bool = false
    var includeStatements: Bool = false
    var includeMarketing: Bool = false
    var includeNewsletters: Bool = false
    var includeShipping: Bool = false
}
