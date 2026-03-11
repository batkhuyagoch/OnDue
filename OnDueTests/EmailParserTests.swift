import XCTest
@testable import OnDue

final class EmailParserTests: XCTestCase {
    func testParserStripsCssArtifactsAndKeepsActionableTailContext() {
        let parser = EmailParser()
        let cssNoise = String(repeating: ".btn { color: red; }\n", count: 500)
        let filler = String(repeating: "newsletter boilerplate text\n", count: 1200)
        let actionable = "Action required: verify your identity before 03/15/2026."
        let message = MessageRecord(
            mailboxAccountId: "acct",
            providerMessageId: "m1",
            internalDate: Date(),
            fromEmail: "alerts@example.com",
            subject: "Security notice",
            snippet: "Please verify",
            bodyText: "\(cssNoise)\n\(filler)\n\(actionable)",
            labelIds: "inbox"
        )

        let parsed = parser.parse(message: message)
        XCTAssertFalse(parsed.bodyText.contains(".btn { color: red; }"))
        XCTAssertTrue(parsed.bodyText.lowercased().contains("verify your identity"))
        XCTAssertLessThanOrEqual(parsed.bodyText.count, EmailContentBudget.parsedContextCharsMax)
        XCTAssertLessThanOrEqual(parsed.normalizedText.count, EmailContentBudget.normalizedTextCharsMax)
    }

    func testParserCapsVeryLargeBody() {
        let parser = EmailParser()
        let hugeBody = String(repeating: "payment due notice ", count: 80_000)
        let message = MessageRecord(
            mailboxAccountId: "acct",
            providerMessageId: "m2",
            internalDate: Date(),
            fromEmail: "billing@example.com",
            subject: "Invoice",
            bodyText: hugeBody
        )

        let parsed = parser.parse(message: message)
        XCTAssertLessThanOrEqual(parsed.bodyText.count, EmailContentBudget.parsedContextCharsMax)
        XCTAssertLessThanOrEqual(parsed.normalizedText.count, EmailContentBudget.normalizedTextCharsMax)
    }

    func testParserRemovesInvisibleEntityNoiseFromBodyAndSnippet() {
        let parser = EmailParser()
        let noisy = "Please verify&#8205;&#847; your account before 03/15/2026."
        let message = MessageRecord(
            mailboxAccountId: "acct",
            providerMessageId: "m3",
            internalDate: Date(),
            fromEmail: "alerts@example.com",
            subject: "Security&#8205; notice",
            snippet: noisy,
            bodyText: noisy
        )

        let parsed = parser.parse(message: message)
        XCTAssertFalse(parsed.bodyText.contains("&#8205;"))
        XCTAssertFalse(parsed.bodyText.contains("&#847;"))
        XCTAssertFalse(parsed.snippet.contains("&#8205;"))
        XCTAssertTrue(parsed.bodyText.lowercased().contains("verify"))
    }
}
