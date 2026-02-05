import XCTest
@testable import OnDue

final class RuleEngineTests: XCTestCase {
    private var engine: RuleEngine!

    override func setUp() {
        super.setUp()
        engine = RuleEngine()
    }

    func testPaymentDueIsDetected() {
        let result = engine.evaluate(email: SampleEmails.paymentDue())
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.category, .payment)
        XCTAssertGreaterThan(result?.score ?? 0.0, 1.0)
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

    func testDateParsingFindsDeadline() {
        let date = DateParsing.parseDate(from: "Payment due March 15")
        XCTAssertNotNil(date)
    }
}
