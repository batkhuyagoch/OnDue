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
        let result = engine.assess(email: SampleEmails.appointmentInvite())
        XCTAssertFalse(result.matchedReasons.isEmpty)
    }

    func testDocumentRequestIsDetected() {
        let result = engine.assess(email: SampleEmails.documentRequest())
        XCTAssertNotEqual(result.decision, .reject)
        XCTAssertEqual(result.category, .document)
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

        for sample in localGoldSamples {
            let assessment = engine.assess(email: sample.email)
            if sample.expectedOutcome == .reject {
                XCTAssertEqual(assessment.decision, .reject, sample.id)
            }

            if assessment.decision == .needsReview {
                needsReviewCount += 1
            }
            if assessment.decision == .reject {
                blockedCount += 1
            }

            if let expected = sample.expectedHypothesis {
                let matched = assessment.matchedRuleIds.contains(expected.rawValue)
                if matched {
                    firedByHypothesis[expected, default: 0] += 1
                }
            }

            XCTAssertFalse(assessment.matchedReasons.contains(where: { reason in
                reason.contains("signal.") || reason.contains("rule_") || reason.contains("weight")
            }))
        }

        let total = localGoldSamples.count
        let needsReviewRatio = Double(needsReviewCount) / Double(max(total, 1))
        XCTAssertLessThanOrEqual(needsReviewRatio, 0.5)

        Logger.info("Hypothesis health summary: fired=\(firedByHypothesis) blocked=\(blockedCount) needsReview=\(needsReviewCount)")
    }

    func testGoldDatasetConfusionAndBlockerLeaks() {
        var tp = 0
        var fp = 0
        var tn = 0
        var fn = 0
        for sample in localGoldSamples {
            let assessment = engine.assess(email: sample.email)
            let expectedPositive = sample.expectedOutcome == .accept || sample.expectedOutcome == .needsReview
            let predictedPositive = assessment.decision == .accept || assessment.decision == .needsReview
            if expectedPositive && predictedPositive { tp += 1 }
            if !expectedPositive && predictedPositive { fp += 1 }
            if !expectedPositive && !predictedPositive { tn += 1 }
            if expectedPositive && !predictedPositive { fn += 1 }
        }
        XCTAssertLessThanOrEqual(fp, 2, "False positives too high for precision-first profile")
        Logger.info("Gold confusion matrix: tp=\(tp) fp=\(fp) tn=\(tn) fn=\(fn)")
    }

    func testBlockerSignalsNeverLeak() {
        let blockerSamples: [ParsedEmail] = [
            SampleEmails.marketingPromo(),
            SampleEmails.promoUrgency(),
            SampleEmails.actionRequiredWithUnsubscribe(),
            SampleEmails.receiptEmail(),
            SampleEmails.securityAlert(),
            SampleEmails.dateOnlyInfo()
        ]
        for sample in blockerSamples {
            let assessment = engine.assess(email: sample)
            XCTAssertEqual(assessment.decision, .reject)
        }
    }

    func testUscisReceiptIsDetected() {
        let result = engine.assess(email: SampleEmails.uscisReceiptNotice())
        XCTAssertFalse(result.matchedReasons.isEmpty)
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

    func testDeliveryActionProducesCoherentReasonCode() {
        let email = ParsedEmail(
            subject: "Delivery attempt failed",
            snippet: "Please reschedule delivery by Friday.",
            bodyText: "Please reschedule delivery. Pick up your package by Friday.",
            sender: "alerts@carrier.com",
            senderDomain: "carrier.com",
            hasAttachments: false,
            labelIds: ["inbox"],
            normalizedText: "delivery attempt failed please reschedule delivery pick up your package by friday"
        )
        let assessment = engine.assess(email: email)
        if assessment.matchedRuleIds.contains(ObligationHypothesis.deliveryRequired.rawValue) {
            XCTAssertNotEqual(assessment.decisionContract.reasonCode, .other)
        }
    }
}

private struct LocalGoldSample {
    let id: String
    let email: ParsedEmail
    let expectedOutcome: ObligationDecision
    let expectedHypothesis: ObligationHypothesis?
}

private let localGoldSamples: [LocalGoldSample] = [
    LocalGoldSample(id: "payment_due", email: SampleEmails.paymentDue(), expectedOutcome: .accept, expectedHypothesis: .paymentFailure),
    LocalGoldSample(id: "document_request", email: SampleEmails.documentRequest(), expectedOutcome: .accept, expectedHypothesis: .userActionRequired),
    LocalGoldSample(id: "date_only", email: SampleEmails.dateOnlyInfo(), expectedOutcome: .reject, expectedHypothesis: nil),
    LocalGoldSample(id: "promo_urgency", email: SampleEmails.promoUrgency(), expectedOutcome: .reject, expectedHypothesis: nil),
    LocalGoldSample(id: "action_with_unsubscribe", email: SampleEmails.actionRequiredWithUnsubscribe(), expectedOutcome: .reject, expectedHypothesis: nil),
    LocalGoldSample(id: "uscis_rfe", email: SampleEmails.uscisRFE(), expectedOutcome: .accept, expectedHypothesis: .legalComplianceResponse),
    LocalGoldSample(id: "court_notice", email: SampleEmails.courtNotice(), expectedOutcome: .accept, expectedHypothesis: .legalComplianceResponse)
]

private final class TestPreferences: FilterPreferencesStoring {
    var includeSecurityAlerts: Bool = false
    var includeStatements: Bool = false
    var includeMarketing: Bool = false
    var includeNewsletters: Bool = false
    var includeShipping: Bool = false
}
