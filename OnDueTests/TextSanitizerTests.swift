import XCTest
@testable import OnDue

final class TextSanitizerTests: XCTestCase {
    func testRemovesUrlsAndTrackingParams() {
        let input = "See https://example.com/path?utm_source=test&gclid=abc and www.example.org."
        let output = TextSanitizer.sanitize(input)
        XCTAssertFalse(output.contains("http"))
        XCTAssertFalse(output.contains("www."))
        XCTAssertFalse(output.lowercased().contains("utm_"))
        XCTAssertFalse(output.lowercased().contains("gclid"))
    }
}
