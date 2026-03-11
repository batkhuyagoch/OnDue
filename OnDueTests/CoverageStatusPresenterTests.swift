import XCTest
@testable import OnDue

final class CoverageStatusPresenterTests: XCTestCase {
    func testDisplayErrorMapsQuotaError() {
        let quotaError = YearScanQuotaStoppedError(
            lastCompletedMonthIndex: 2,
            totalMonths: 12,
            resumeState: YearScanResumeState(
                accountIndex: 0,
                monthIndex: 3,
                totalMonths: 12,
                phase: .backfill,
                beforeDate: nil,
                beforePk: nil,
                scannedMessageCount: 120,
                lastStatusMessage: nil,
                consecutiveQuotaHits: 1
            )
        )

        let mapped = CoverageStatusPresenter.displayError(from: quotaError)
        XCTAssertEqual(mapped, .quota)
        XCTAssertEqual(
            CoverageStatusPresenter.errorMessage(for: mapped),
            "Gmail API limit reached. Your progress is saved and you can resume shortly."
        )
    }

    func testTitleForCompletedWithFindings() {
        XCTAssertEqual(
            CoverageStatusPresenter.title(for: .completed(hasFindings: true)),
            "Items may need attention"
        )
    }

    func testProgressMessageMapsBackfillToFriendlyMonthCopy() {
        let raw = "Backfilling: Jun 2025 (6/12)"
        XCTAssertEqual(
            CoverageStatusPresenter.progressMessage(from: raw),
            "Scanning month 6 of 12..."
        )
    }

    func testProgressMessageMapsScanningCountToFriendlyCopy() {
        let raw = "Scanning inbox... 1240 messages"
        XCTAssertEqual(
            CoverageStatusPresenter.progressMessage(from: raw),
            "1240 messages scanned so far."
        )
    }

    func testProgressMessageMapsDeviceConstraintPauseCopy() {
        let raw = "Scanning paused briefly. Optimizing for device memory..."
        XCTAssertEqual(
            CoverageStatusPresenter.progressMessage(from: raw),
            "Optimizing for device memory..."
        )
    }
}

