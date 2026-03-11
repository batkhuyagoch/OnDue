import XCTest
@testable import OnDue

final class YearScanBackgroundManagerTests: XCTestCase {
    func testBackgroundStatusUsesResumePhaseAndMonth() {
        let resume = YearScanResumeState(
            accountIndex: 0,
            monthIndex: 4,
            totalMonths: 12,
            phase: .backfill,
            beforeDate: nil,
            beforePk: nil,
            scannedMessageCount: 100,
            lastStatusMessage: nil,
            consecutiveQuotaHits: 0
        )

        let status = YearScanBackgroundManager.backgroundStatus(for: resume)
        XCTAssertEqual(status, "Resuming in background at month 5 of 12...")
    }

    func testScannedCountParsesFromStatusMessage() {
        XCTAssertEqual(
            YearScanBackgroundManager.scannedCount(from: "Scanning inbox... 1240 messages"),
            1240
        )
        XCTAssertNil(YearScanBackgroundManager.scannedCount(from: "Backfilling: Jan 2026 (1/12)"))
    }
}

