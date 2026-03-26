import XCTest
@testable import OnDue

final class YearScanLifecycleStateTests: XCTestCase {
    func testBannerStateRejectsBackfillAfterScanningState() {
        let current = YearScanResumeState(
            accountIndex: 0,
            monthIndex: 12,
            totalMonths: 12,
            phase: .scanning,
            beforeDate: Date(timeIntervalSince1970: 1_700_000_000),
            beforePk: 100,
            scannedMessageCount: 1_000,
            lastStatusMessage: "Scanning inbox... 1000 messages",
            consecutiveQuotaHits: 0,
            currentPage: 12
        )
        let staleBackfill = YearScanResumeState(
            accountIndex: 0,
            monthIndex: 3,
            totalMonths: 12,
            phase: .backfill,
            beforeDate: nil,
            beforePk: nil,
            scannedMessageCount: 300,
            lastStatusMessage: "Backfilling: Apr 2025 (4/12)",
            consecutiveQuotaHits: 0
        )

        XCTAssertFalse(YearScanState.shouldApplyResumeState(current: current, incoming: staleBackfill))
    }

    func testViewModelRejectsOlderScanningPage() {
        let current = YearScanResumeState(
            accountIndex: 0,
            monthIndex: 12,
            totalMonths: 12,
            phase: .scanning,
            beforeDate: Date(timeIntervalSince1970: 1_700_000_010),
            beforePk: 120,
            scannedMessageCount: 1_200,
            lastStatusMessage: "Scanning inbox... 1200 messages",
            consecutiveQuotaHits: 0,
            currentPage: 15
        )
        let staleScanningPage = YearScanResumeState(
            accountIndex: 0,
            monthIndex: 12,
            totalMonths: 12,
            phase: .scanning,
            beforeDate: Date(timeIntervalSince1970: 1_700_000_000),
            beforePk: 119,
            scannedMessageCount: 1_190,
            lastStatusMessage: "Scanning inbox... 1190 messages",
            consecutiveQuotaHits: 0,
            currentPage: 14
        )

        XCTAssertFalse(YearScanState.shouldApplyResumeState(current: current, incoming: staleScanningPage))
    }

    func testSamePageLowerMessageCountRejected() {
        let current = YearScanResumeState(
            accountIndex: 0,
            monthIndex: 12,
            totalMonths: 12,
            phase: .scanning,
            beforeDate: Date(timeIntervalSince1970: 1_700_000_010),
            beforePk: 120,
            scannedMessageCount: 1_200,
            lastStatusMessage: nil,
            consecutiveQuotaHits: 0,
            currentPage: 15
        )
        let samePageLower = YearScanResumeState(
            accountIndex: 0,
            monthIndex: 12,
            totalMonths: 12,
            phase: .scanning,
            beforeDate: Date(timeIntervalSince1970: 1_700_000_010),
            beforePk: 120,
            scannedMessageCount: 1_100,
            lastStatusMessage: nil,
            consecutiveQuotaHits: 0,
            currentPage: 15
        )

        XCTAssertFalse(YearScanState.shouldApplyResumeState(current: current, incoming: samePageLower))
        XCTAssertFalse(YearScanState.shouldApplyResumeState(current: current, incoming: samePageLower))
    }

    func testEarlierAccountIndexRejected() {
        let current = YearScanResumeState(
            accountIndex: 1,
            monthIndex: 3,
            totalMonths: 12,
            phase: .backfill,
            beforeDate: nil,
            beforePk: nil,
            scannedMessageCount: 500,
            lastStatusMessage: nil,
            consecutiveQuotaHits: 0
        )
        let staleAccount = YearScanResumeState(
            accountIndex: 0,
            monthIndex: 11,
            totalMonths: 12,
            phase: .scanning,
            beforeDate: Date(timeIntervalSince1970: 1_700_000_000),
            beforePk: 99,
            scannedMessageCount: 2000,
            lastStatusMessage: nil,
            consecutiveQuotaHits: 0,
            currentPage: 20
        )

        XCTAssertFalse(YearScanState.shouldApplyResumeState(current: current, incoming: staleAccount))
        XCTAssertFalse(YearScanState.shouldApplyResumeState(current: current, incoming: staleAccount))
    }

    func testNilCurrentAlwaysAccepts() {
        let incoming = YearScanResumeState(
            accountIndex: 0,
            monthIndex: 0,
            totalMonths: 12,
            phase: .backfill,
            beforeDate: nil,
            beforePk: nil,
            scannedMessageCount: 0,
            lastStatusMessage: nil,
            consecutiveQuotaHits: 0
        )

        XCTAssertTrue(YearScanState.shouldApplyResumeState(current: nil, incoming: incoming))
        XCTAssertTrue(YearScanState.shouldApplyResumeState(current: nil, incoming: incoming))
    }

    func testLaterBackfillMonthAccepted() {
        let current = YearScanResumeState(
            accountIndex: 0,
            monthIndex: 3,
            totalMonths: 12,
            phase: .backfill,
            beforeDate: nil,
            beforePk: nil,
            scannedMessageCount: 300,
            lastStatusMessage: nil,
            consecutiveQuotaHits: 0
        )
        let later = YearScanResumeState(
            accountIndex: 0,
            monthIndex: 5,
            totalMonths: 12,
            phase: .backfill,
            beforeDate: nil,
            beforePk: nil,
            scannedMessageCount: 500,
            lastStatusMessage: nil,
            consecutiveQuotaHits: 0
        )

        XCTAssertTrue(YearScanState.shouldApplyResumeState(current: current, incoming: later))
        XCTAssertTrue(YearScanState.shouldApplyResumeState(current: current, incoming: later))
    }
}
