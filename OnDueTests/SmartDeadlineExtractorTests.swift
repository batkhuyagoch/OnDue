import XCTest
@testable import OnDue

final class SmartDeadlineExtractorTests: XCTestCase {

    private let calendar = Calendar.current
    private lazy var referenceDate: Date = {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 3
        comps.day = 1
        comps.hour = 12
        return calendar.date(from: comps)!
    }()

    // MARK: - Layer 1: Subject line

    func testSubjectWithDueKeywordAndDate() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Payment due March 25",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "payment due march 25",
            referenceDate: referenceDate
        )
        guard let result else { return XCTFail("Expected non-nil result") }
        XCTAssertEqual(result.source, .subjectKeyword)
        XCTAssertEqual(calendar.component(.month, from: result.date), 3)
        XCTAssertEqual(calendar.component(.day, from: result.date), 25)
    }

    func testSubjectWithNoDeadlineKeyword() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Your February statement",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "your february statement",
            referenceDate: referenceDate
        )
        XCTAssertNil(result)
    }

    func testSubjectWithActionRequiredByFriday() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Action required by Friday",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "action required by friday",
            referenceDate: referenceDate
        )
        guard let result else { return XCTFail("Expected non-nil result") }
        XCTAssertEqual(result.source, .subjectKeyword)
        let weekday = calendar.component(.weekday, from: result.date)
        XCTAssertEqual(weekday, 6, "Should be Friday")
    }

    func testSubjectWithDeadlineExpires() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Your offer expires March 15",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "your offer expires march 15",
            referenceDate: referenceDate
        )
        guard let result else { return XCTFail("Expected non-nil result") }
        XCTAssertEqual(result.source, .subjectKeyword)
        XCTAssertEqual(calendar.component(.day, from: result.date), 15)
    }

    // MARK: - Layer 2: HTML table labels

    func testHtmlTableWithDueDateLabel() {
        let html = """
        <table>
            <tr><td>Due Date</td><td>March 25, 2026</td></tr>
        </table>
        """
        let result = SmartDeadlineExtractor.extract(
            subject: "Your bill",
            bodyHtml: html,
            actionableWindowText: nil,
            normalizedText: "your bill due date march 25 2026",
            referenceDate: referenceDate
        )
        guard let result else { return XCTFail("Expected non-nil result") }
        XCTAssertEqual(result.source, .htmlTableLabel)
        XCTAssertEqual(calendar.component(.month, from: result.date), 3)
        XCTAssertEqual(calendar.component(.day, from: result.date), 25)
    }

    func testHtmlTableWithPaymentDueLabel() {
        let html = """
        <table><tr><th>Payment Due</th><td>April 10, 2026</td></tr></table>
        """
        let result = SmartDeadlineExtractor.extract(
            subject: "Invoice",
            bodyHtml: html,
            actionableWindowText: nil,
            normalizedText: "invoice payment due april 10 2026",
            referenceDate: referenceDate
        )
        guard let result else { return XCTFail("Expected non-nil result") }
        XCTAssertEqual(result.source, .htmlTableLabel)
        XCTAssertEqual(calendar.component(.month, from: result.date), 4)
        XCTAssertEqual(calendar.component(.day, from: result.date), 10)
    }

    func testHtmlTableWithStatementPeriodIsSkipped() {
        let html = """
        <table><tr><td>Statement Period</td><td>Feb 1 - Feb 28</td></tr></table>
        """
        let result = SmartDeadlineExtractor.extract(
            subject: "Your statement",
            bodyHtml: html,
            actionableWindowText: nil,
            normalizedText: "",
            referenceDate: referenceDate
        )
        XCTAssertNil(result)
    }

    func testNilBodyHtmlGracefullySkipped() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Your bill",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "",
            referenceDate: referenceDate
        )
        XCTAssertNil(result)
    }

    // MARK: - Layer 3: Actionable windows

    func testActionableWindowWithDueByKeyword() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Reminder",
            bodyHtml: nil,
            actionableWindowText: "please pay the amount due by March 25",
            normalizedText: "reminder please pay the amount due by march 25",
            referenceDate: referenceDate
        )
        guard let result else { return XCTFail("Expected non-nil result") }
        XCTAssertEqual(result.source, .actionableWindow)
        XCTAssertEqual(calendar.component(.month, from: result.date), 3)
        XCTAssertEqual(calendar.component(.day, from: result.date), 25)
    }

    // MARK: - Anti-pattern tests

    func testAntiPatternStatementPeriodFiltered() {
        let text = "statement period ending february 28. payment due march 25."
        let result = SmartDeadlineExtractor.extract(
            subject: "Bill notice",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: text,
            referenceDate: referenceDate
        )
        guard let result else { return XCTFail("Expected non-nil result for anti-pattern test") }
        XCTAssertEqual(calendar.component(.month, from: result.date), 3)
        XCTAssertEqual(calendar.component(.day, from: result.date), 25)
    }

    func testAntiPatternSentOnFiltered() {
        let text = "sent on march 1. deadline: march 15."
        let result = SmartDeadlineExtractor.extract(
            subject: "Action needed",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: text,
            referenceDate: referenceDate
        )
        guard let result else { return XCTFail("Expected non-nil result for anti-pattern test") }
        XCTAssertEqual(calendar.component(.day, from: result.date), 15)
    }

    func testAntiPatternTransactionOnFiltered() {
        let text = "transaction on march 1. due by march 25."
        let result = SmartDeadlineExtractor.extract(
            subject: "Payment reminder",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: text,
            referenceDate: referenceDate
        )
        guard let result else { return XCTFail("Expected non-nil result for anti-pattern test") }
        XCTAssertEqual(calendar.component(.day, from: result.date), 25)
    }

    func testIsNearAntiPatternDetectsStatementPeriod() {
        let text = "statement period ending march 25 something something"
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 3
        comps.day = 25
        let date = calendar.date(from: comps)!
        XCTAssertTrue(SmartDeadlineExtractor.isNearAntiPattern(date: date, in: text))
    }

    func testIsNearAntiPatternAllowsCleanDate() {
        let text = "payment due march 25 please pay"
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 3
        comps.day = 25
        let date = calendar.date(from: comps)!
        XCTAssertFalse(SmartDeadlineExtractor.isNearAntiPattern(date: date, in: text))
    }

    // MARK: - Relative dates

    func testRelativeDateInThreeDays() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Expires in 3 days",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "your policy expires in 3 days",
            referenceDate: referenceDate
        )
        guard let result else { return XCTFail("Expected non-nil result") }
        let expected = calendar.date(byAdding: .day, value: 3, to: referenceDate)!
        let daysDiff = calendar.dateComponents([.day], from: result.date, to: expected).day ?? 99
        XCTAssertTrue(abs(daysDiff) <= 1, "Should be approximately 3 days from reference")
    }

    func testRelativeDateNextFriday() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Due next Friday",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "due next friday",
            referenceDate: referenceDate
        )
        XCTAssertNotNil(result)
    }

    // MARK: - Fallback tests

    func testFallbackWithDateButNoKeywords() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Hello",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "your appointment is on march 20 at the downtown office",
            referenceDate: referenceDate
        )
        if let result {
            XCTAssertTrue(
                result.source == .bodyDateExtractor || result.source == .bodyFallback,
                "Should be body-level extraction"
            )
        }
    }

    func testNoDateReturnsNil() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Hello",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "thank you for your order",
            referenceDate: referenceDate
        )
        XCTAssertNil(result)
    }

    // MARK: - Layer priority tests

    func testSubjectWinsOverBody() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Payment due March 10",
            bodyHtml: nil,
            actionableWindowText: "amount due by March 25",
            normalizedText: "payment due march 10 amount due by march 25",
            referenceDate: referenceDate
        )
        guard let result else { return XCTFail("Expected non-nil result") }
        XCTAssertEqual(result.source, .subjectKeyword)
        XCTAssertEqual(calendar.component(.day, from: result.date), 10)
    }

    func testHtmlTableWinsOverActionableWindow() {
        let html = """
        <table><tr><td>Due Date</td><td>March 15, 2026</td></tr></table>
        """
        let result = SmartDeadlineExtractor.extract(
            subject: "Your bill",
            bodyHtml: html,
            actionableWindowText: "pay by March 25",
            normalizedText: "your bill due date march 15 2026 pay by march 25",
            referenceDate: referenceDate
        )
        guard let result else { return XCTFail("Expected non-nil result") }
        XCTAssertEqual(result.source, .htmlTableLabel)
        XCTAssertEqual(calendar.component(.day, from: result.date), 15)
    }

    // MARK: - DeadlineSource codable

    func testDeadlineSourceRoundTrip() throws {
        for source in [DeadlineSource.subjectKeyword, .htmlTableLabel, .actionableWindow, .bodyDateExtractor, .bodyFallback] {
            let data = try JSONEncoder().encode(source)
            let decoded = try JSONDecoder().decode(DeadlineSource.self, from: data)
            XCTAssertEqual(decoded, source)
        }
    }

    // MARK: - ParsedEmail struct fields

    func testParsedEmailHasBodyHtmlField() {
        let email = ParsedEmail(
            subject: "Bill",
            snippet: "",
            bodyText: "",
            sender: "billing@example.com",
            senderDomain: "example.com",
            hasAttachments: false,
            labelIds: [],
            normalizedText: "",
            actionableWindowText: "pay by March 25",
            bodyHtml: "<p>Some HTML</p>"
        )
        XCTAssertEqual(email.bodyHtml, "<p>Some HTML</p>")
        XCTAssertEqual(email.actionableWindowText, "pay by March 25")
    }

    func testParsedEmailBodyHtmlCanBeNil() {
        let email = ParsedEmail(
            subject: "Test",
            snippet: "",
            bodyText: "Hello world",
            sender: "sender@example.com",
            senderDomain: nil,
            hasAttachments: false,
            labelIds: [],
            normalizedText: "test hello world",
            actionableWindowText: nil,
            bodyHtml: nil
        )
        XCTAssertNil(email.bodyHtml)
        XCTAssertNil(email.actionableWindowText)
    }

    // MARK: - Year rollover (reference-date correctness)

    func testYearRolloverDecemberReferenceJanuaryDue() {
        var comps = DateComponents()
        comps.year = 2025
        comps.month = 12
        comps.day = 15
        comps.hour = 12
        let decRef = calendar.date(from: comps)!

        let result = SmartDeadlineExtractor.extract(
            subject: "Payment due January 10",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "payment due january 10",
            referenceDate: decRef
        )
        guard let result else { return XCTFail("Expected non-nil result for year rollover") }
        XCTAssertEqual(calendar.component(.month, from: result.date), 1)
        XCTAssertEqual(calendar.component(.day, from: result.date), 10)
        XCTAssertEqual(calendar.component(.year, from: result.date), 2026,
                       "January date should roll to next year when reference is December")
    }

    func testExplicitYearDoesNotRoll() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Due by March 1, 2026",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "due by march 1, 2026",
            referenceDate: referenceDate
        )
        guard let result else { return XCTFail("Expected non-nil result") }
        XCTAssertEqual(calendar.component(.year, from: result.date), 2026)
        XCTAssertEqual(calendar.component(.month, from: result.date), 3)
    }

    // MARK: - Ordinal and punctuated month names

    func testOrdinalDateSuffix() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Due by March 25th",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "due by march 25th",
            referenceDate: referenceDate
        )
        guard let result else { return XCTFail("Expected non-nil result for ordinal") }
        XCTAssertEqual(result.source, .subjectKeyword)
        XCTAssertEqual(calendar.component(.day, from: result.date), 25)
    }

    func testAbbreviatedMonthWithDot() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Deadline: Apr. 5",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "deadline: apr. 5",
            referenceDate: referenceDate
        )
        guard let result else { return XCTFail("Expected non-nil result for abbreviated month") }
        XCTAssertEqual(calendar.component(.month, from: result.date), 4)
        XCTAssertEqual(calendar.component(.day, from: result.date), 5)
    }

    // MARK: - Numeric date formats

    func testNumericSlashDateMDY() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Payment due",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "your bill is due by 4/9/2026",
            referenceDate: referenceDate
        )
        guard let result else { return XCTFail("Expected non-nil result for M/D/YYYY") }
        XCTAssertEqual(calendar.component(.month, from: result.date), 4)
        XCTAssertEqual(calendar.component(.day, from: result.date), 9)
        XCTAssertEqual(calendar.component(.year, from: result.date), 2026)
    }

    func testNumericSlashDateMD() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Payment due",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "your bill is due by 3/25",
            referenceDate: referenceDate
        )
        guard let result else { return XCTFail("Expected non-nil result for M/D") }
        XCTAssertEqual(calendar.component(.month, from: result.date), 3)
        XCTAssertEqual(calendar.component(.day, from: result.date), 25)
    }

    func testNumericSlashDateZeroPadded() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Payment due",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "your bill is due by 03/05/2026",
            referenceDate: referenceDate
        )
        guard let result else { return XCTFail("Expected non-nil result for 0-padded") }
        XCTAssertEqual(calendar.component(.month, from: result.date), 3)
        XCTAssertEqual(calendar.component(.day, from: result.date), 5)
    }

    // MARK: - Invalid / impossible dates

    func testImpossibleDateFeb30ReturnsNil() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Due February 30",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "due february 30",
            referenceDate: referenceDate
        )
        XCTAssertNil(result, "February 30 is not a real date")
    }

    func testImpossibleNumericDate() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Payment due",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "due by 13/40/2026",
            referenceDate: referenceDate
        )
        XCTAssertNil(result, "Month 13 day 40 is not valid")
    }

    // MARK: - Anti-pattern sentence boundary precision

    func testAntiPatternDoesNotLeakAcrossSentences() {
        let text = "billing period ending march 1. your payment is due march 25."
        let result = SmartDeadlineExtractor.extract(
            subject: "Statement",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: text,
            referenceDate: referenceDate
        )
        guard let result else { return XCTFail("Expected non-nil: anti-pattern in previous sentence shouldn't block next") }
        XCTAssertEqual(calendar.component(.day, from: result.date), 25)
    }

    func testAntiPatternWithinSameSentenceBlocks() {
        let text = "statement period ending march 25 is enclosed here"
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 25
        let date = calendar.date(from: comps)!
        XCTAssertTrue(SmartDeadlineExtractor.isNearAntiPattern(date: date, in: text))
    }

    // MARK: - Phantom date regression

    func testPaymentDueWithNoDateDoesNotHallucinateToday() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Payment due",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "please make your payment as soon as possible",
            referenceDate: referenceDate
        )
        if let result {
            let daysDiff = abs(calendar.dateComponents([.day], from: referenceDate, to: result.date).day ?? 0)
            XCTAssertTrue(daysDiff > 0, "Should not return today's date as a phantom deadline")
        }
    }

    // MARK: - Fallback uses reference date (not wall clock)

    func testFallbackRespectsReferenceDate() {
        var comps = DateComponents()
        comps.year = 2024; comps.month = 6; comps.day = 1; comps.hour = 12
        let historicRef = calendar.date(from: comps)!

        let result = SmartDeadlineExtractor.extract(
            subject: "Reminder",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "your appointment is on july 15",
            referenceDate: historicRef
        )
        guard let result else { return XCTFail("Expected non-nil result from fallback") }
        XCTAssertEqual(calendar.component(.year, from: result.date), 2024,
                       "Fallback should use reference year 2024, not current wall-clock year")
        XCTAssertEqual(calendar.component(.month, from: result.date), 7)
        XCTAssertEqual(calendar.component(.day, from: result.date), 15)
    }

    // MARK: - Layer precedence additional checks

    func testFallbackOnlyTriggersWhenHigherLayersFail() {
        let result = SmartDeadlineExtractor.extract(
            subject: "No keywords here",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "your appointment march 20",
            referenceDate: referenceDate
        )
        if let result {
            XCTAssertTrue(
                result.source == .bodyDateExtractor || result.source == .bodyFallback,
                "With no subject keyword/html/actionable, should only be body-level or fallback"
            )
        }
    }

    func testActionableWindowWinsOverBody() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Reminder",
            bodyHtml: nil,
            actionableWindowText: "pay by April 5",
            normalizedText: "your bill due march 25. pay by april 5.",
            referenceDate: referenceDate
        )
        guard let result else { return XCTFail("Expected non-nil result") }
        XCTAssertEqual(result.source, .actionableWindow)
        XCTAssertEqual(calendar.component(.month, from: result.date), 4)
        XCTAssertEqual(calendar.component(.day, from: result.date), 5)
    }

    // MARK: - Real-world regression: receipt / confirmation emails

    func testPaymentReceiptShouldNotProduceDeadline() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Thanks for your payment!",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "you've paid your boost bill payment received on march 20 2026",
            referenceDate: referenceDate
        )
        XCTAssertNil(result,
                     "Receipt confirmation with 'paid your' and 'payment received on' should not produce a deadline")
    }

    func testReservationDateIsExtractedAsDeadline() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Sport Fit Milwaukee Reservation for Smash & Burn on 3/14/2026 at 10:00 AM",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "this confirms your reservation for smash & burn on 3/14/2026 at 10:00 am at sport fit milwaukee",
            referenceDate: referenceDate
        )
        guard let result else { return XCTFail("Reservation date IS a real deadline — you need to show up") }
        XCTAssertEqual(calendar.component(.month, from: result.date), 3)
        XCTAssertEqual(calendar.component(.day, from: result.date), 14)
        XCTAssertEqual(calendar.component(.year, from: result.date), 2026)
    }

    func testReceiptForAmountIsFiltered() {
        let result = SmartDeadlineExtractor.extract(
            subject: "Receipt for your purchase",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: "receipt for $50 on march 15. thank you for your purchase.",
            referenceDate: referenceDate
        )
        XCTAssertNil(result,
                     "Receipt date should be filtered by anti-pattern")
    }

    func testPaidOnDateFilteredButDueByKept() {
        let text = "paid on march 1. next payment due by march 25."
        let result = SmartDeadlineExtractor.extract(
            subject: "Account update",
            bodyHtml: nil,
            actionableWindowText: nil,
            normalizedText: text,
            referenceDate: referenceDate
        )
        guard let result else { return XCTFail("Expected non-nil: 'due by march 25' should survive") }
        XCTAssertEqual(calendar.component(.day, from: result.date), 25)
    }
}
