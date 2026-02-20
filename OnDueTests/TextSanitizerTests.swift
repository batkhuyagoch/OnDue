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
}
