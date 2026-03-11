import XCTest
@testable import OnDue

final class YearScanRunnerReliabilityTests: XCTestCase {
    func testThrottleDecisionUsesCooldownToAvoidRepeatedHardPauses() {
        var state = YearScanRunner.ThrottleState()
        let snapshot = YearScanRunner.RuntimeSnapshot(
            thermalState: .nominal,
            isLowPowerModeEnabled: false,
            memoryUsedBytes: 900_000_000
        )
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        let first = YearScanRunner.makeThrottleDecision(
            snapshot: snapshot,
            now: t0,
            state: &state,
            intensity: .balanced
        )
        XCTAssertTrue(first.shouldPause)
        XCTAssertEqual(first.reason, .memory)
        XCTAssertEqual(first.batchSize, 50)

        let second = YearScanRunner.makeThrottleDecision(
            snapshot: snapshot,
            now: t0.addingTimeInterval(5),
            state: &state,
            intensity: .balanced
        )
        XCTAssertFalse(second.shouldPause)
        XCTAssertEqual(second.reason, .memory)
        XCTAssertEqual(second.batchSize, 75)

        let third = YearScanRunner.makeThrottleDecision(
            snapshot: snapshot,
            now: t0.addingTimeInterval(30),
            state: &state,
            intensity: .balanced
        )
        XCTAssertTrue(third.shouldPause)
        XCTAssertEqual(third.batchSize, 50)
    }

    func testNormalizeResumeStateClampsAndCleansInvalidCursor() {
        let raw = YearScanResumeState(
            accountIndex: -5,
            monthIndex: 99,
            totalMonths: 999,
            phase: .scanning,
            beforeDate: Date(),
            beforePk: nil,
            scannedMessageCount: 42,
            lastStatusMessage: "Scanning inbox... 42 messages",
            consecutiveQuotaHits: 0
        )

        let normalized = YearScanRunner.normalizeResumeState(raw, accountsCount: 2, totalMonths: 12)
        XCTAssertNotNil(normalized)
        XCTAssertEqual(normalized?.accountIndex, 0)
        XCTAssertEqual(normalized?.monthIndex, 12)
        XCTAssertEqual(normalized?.totalMonths, 12)
        XCTAssertNil(normalized?.beforeDate)
        XCTAssertNil(normalized?.beforePk)
    }

    func testLowPowerDecisionReducesBatchWithoutPause() {
        var state = YearScanRunner.ThrottleState()
        let snapshot = YearScanRunner.RuntimeSnapshot(
            thermalState: .nominal,
            isLowPowerModeEnabled: true,
            memoryUsedBytes: 120_000_000
        )

        let decision = YearScanRunner.makeThrottleDecision(
            snapshot: snapshot,
            now: Date(),
            state: &state,
            intensity: .balanced
        )
        XCTAssertFalse(decision.shouldPause)
        XCTAssertEqual(decision.reason, .lowPower)
        XCTAssertEqual(decision.batchSize, 120)
    }

    func testFasterIntensityIncreasesNominalBatchSize() {
        var state = YearScanRunner.ThrottleState()
        let snapshot = YearScanRunner.RuntimeSnapshot(
            thermalState: .nominal,
            isLowPowerModeEnabled: false,
            memoryUsedBytes: 120_000_000
        )

        let decision = YearScanRunner.makeThrottleDecision(
            snapshot: snapshot,
            now: Date(),
            state: &state,
            intensity: .faster
        )

        XCTAssertFalse(decision.shouldPause)
        XCTAssertEqual(decision.batchSize, 500)
    }
}
