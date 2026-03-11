import XCTest
@testable import OnDue

final class TextSanitizerTests: XCTestCase {
    func testSanitizeDetailMessageRemovesCssStyleBlocks() {
        let html = """
        <html><head>
        <style>
        .container { color: red; }
        body { font-size: 14px; }
        </style>
        </head>
        <body>
        <div>Payment due by March 20, 2026</div>
        </body></html>
        """

        let detail = TextSanitizer.sanitizeDetailMessage(
            bodyText: nil,
            bodyHtml: html,
            snippet: nil
        )
        XCTAssertNotNil(detail)
        XCTAssertFalse(detail?.full.contains(".container") ?? true)
        XCTAssertTrue(detail?.full.lowercased().contains("payment due") ?? false)
    }

    func testSanitizeDetailMessageAppliesBounds() {
        let veryLarge = String(repeating: "A", count: EmailContentBudget.detailFullSafeCharsMax + 5000)
        let detail = TextSanitizer.sanitizeDetailMessage(
            bodyText: veryLarge,
            bodyHtml: nil,
            snippet: nil
        )
        XCTAssertNotNil(detail)
        XCTAssertLessThanOrEqual(detail?.full.count ?? 0, EmailContentBudget.detailFullSafeCharsMax)
        XCTAssertLessThanOrEqual(detail?.preview.count ?? 0, EmailContentBudget.detailPreviewCharsMax)
        XCTAssertEqual(detail?.isTruncated, true)
    }

    func testRemovesUrlsAndTrackingParams() {
        let input = "See https://example.com/path?utm_source=test&gclid=abc and www.example.org."
        let output = TextSanitizer.sanitize(input)
        XCTAssertFalse(output.contains("http"))
        XCTAssertFalse(output.contains("www."))
        XCTAssertFalse(output.lowercased().contains("utm_"))
        XCTAssertFalse(output.lowercased().contains("gclid"))
    }

    func testSanitizeDetailMessageRemovesSplitNumericEntityNoise() {
        let noisy = """
        Thanks for your payment! 96 You've paid your Boost bill
        &#8199;&#8199;&#8199;&#8199; &#8199;&
        #8199;&#8199;&#8199;&#8199;&#8199;
        &#8199;&#8205;&#847; &#8199;&#847;
        """

        let detail = TextSanitizer.sanitizeDetailMessage(
            bodyText: noisy,
            bodyHtml: nil,
            snippet: nil
        )

        XCTAssertNotNil(detail)
        XCTAssertTrue(detail?.full.contains("Thanks for your payment") ?? false)
        XCTAssertFalse(detail?.full.contains("&#") ?? true)
        XCTAssertFalse(detail?.full.contains("\u{2007}") ?? true)
        XCTAssertFalse(detail?.full.contains("\u{200D}") ?? true)
        XCTAssertFalse(detail?.full.contains("\u{034F}") ?? true)
    }

    func testSanitizeDetailMessageDecodesNamedEntities() {
        let noisy = "&shy; &shy; &nbsp; Payment was processed &amp; confirmed."
        let detail = TextSanitizer.sanitizeDetailMessage(
            bodyText: noisy,
            bodyHtml: nil,
            snippet: nil
        )

        XCTAssertNotNil(detail)
        XCTAssertFalse(detail?.full.contains("&shy;") ?? true)
        XCTAssertFalse(detail?.full.contains("&nbsp;") ?? true)
        XCTAssertFalse(detail?.full.contains("&amp;") ?? true)
        XCTAssertTrue(detail?.full.contains("Payment was processed & confirmed.") ?? false)
    }
}
