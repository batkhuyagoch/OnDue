import XCTest
@testable import OnDue

final class YearScanViewModelStateTests: XCTestCase {
    func testDeriveStateRunningWins() {
        let state = YearScanViewModel.deriveUIState(
            isLoading: true,
            hasError: true,
            isInProgress: true,
            hasResults: true,
            lastChecked: Date(),
            scannedMessageCount: 1
        )

        XCTAssertEqual(state, .running)
    }

    func testDeriveStatePausedWhenInProgress() {
        let state = YearScanViewModel.deriveUIState(
            isLoading: false,
            hasError: false,
            isInProgress: true,
            hasResults: false,
            lastChecked: nil,
            scannedMessageCount: 500
        )

        XCTAssertEqual(state, .paused)
    }

    func testDeriveStateCompletedWithoutFindings() {
        let state = YearScanViewModel.deriveUIState(
            isLoading: false,
            hasError: false,
            isInProgress: false,
            hasResults: false,
            lastChecked: Date(),
            scannedMessageCount: 500
        )

        XCTAssertEqual(state, .completed(hasFindings: false))
    }
}

