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
        XCTAssertEqual(first.batchSize, 30)

        let second = YearScanRunner.makeThrottleDecision(
            snapshot: snapshot,
            now: t0.addingTimeInterval(5),
            state: &state,
            intensity: .balanced
        )
        XCTAssertFalse(second.shouldPause)
        XCTAssertEqual(second.reason, .memory)
        XCTAssertEqual(second.batchSize, 50)

        let third = YearScanRunner.makeThrottleDecision(
            snapshot: snapshot,
            now: t0.addingTimeInterval(30),
            state: &state,
            intensity: .balanced
        )
        XCTAssertTrue(third.shouldPause)
        XCTAssertEqual(third.batchSize, 30)
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
        XCTAssertEqual(decision.batchSize, 80)
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

    func testHighMemoryPressureBatchSizeReduced() {
        var state = YearScanRunner.ThrottleState()
        let snapshot = YearScanRunner.RuntimeSnapshot(
            thermalState: .nominal,
            isLowPowerModeEnabled: false,
            memoryUsedBytes: 560_000_000
        )

        let decision = YearScanRunner.makeThrottleDecision(
            snapshot: snapshot,
            now: Date(),
            state: &state,
            intensity: .balanced
        )
        XCTAssertFalse(decision.shouldPause)
        XCTAssertEqual(decision.reason, .memory)
        XCTAssertEqual(decision.batchSize, 70)
    }

    func testWarningMemoryPressureBatchSizeReduced() {
        var state = YearScanRunner.ThrottleState()
        let snapshot = YearScanRunner.RuntimeSnapshot(
            thermalState: .nominal,
            isLowPowerModeEnabled: false,
            memoryUsedBytes: 460_000_000
        )

        let decision = YearScanRunner.makeThrottleDecision(
            snapshot: snapshot,
            now: Date(),
            state: &state,
            intensity: .balanced
        )
        XCTAssertFalse(decision.shouldPause)
        XCTAssertEqual(decision.reason, .memory)
        XCTAssertEqual(decision.batchSize, 120)
    }

    func testRecoveryBatchSizeReduced() {
        var state = YearScanRunner.ThrottleState()
        let highMem = YearScanRunner.RuntimeSnapshot(
            thermalState: .nominal,
            isLowPowerModeEnabled: false,
            memoryUsedBytes: 900_000_000
        )
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = YearScanRunner.makeThrottleDecision(
            snapshot: highMem,
            now: t0,
            state: &state,
            intensity: .balanced
        )

        let nominalSnapshot = YearScanRunner.RuntimeSnapshot(
            thermalState: .nominal,
            isLowPowerModeEnabled: false,
            memoryUsedBytes: 200_000_000
        )
        let recovery = YearScanRunner.makeThrottleDecision(
            snapshot: nominalSnapshot,
            now: t0.addingTimeInterval(10),
            state: &state,
            intensity: .balanced
        )
        XCTAssertEqual(recovery.reason, .recovery)
        XCTAssertEqual(recovery.batchSize, 150)
    }

    func testBatterySaverReducesBatchSizeFurther() {
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
            intensity: .batterySaver
        )
        XCTAssertFalse(decision.shouldPause)
        XCTAssertEqual(decision.batchSize, max(50, Int(Double(80) * 0.75)))
    }

    func testResumeStateGuardRejectsStaleBackfill() {
        let current = YearScanResumeState(
            accountIndex: 0,
            monthIndex: 12,
            totalMonths: 12,
            phase: .scanning,
            beforeDate: nil,
            beforePk: nil,
            scannedMessageCount: 2000,
            lastStatusMessage: nil,
            consecutiveQuotaHits: 0,
            currentPage: 5
        )
        let stale = YearScanResumeState(
            accountIndex: 0,
            monthIndex: 6,
            totalMonths: 12,
            phase: .backfill,
            beforeDate: nil,
            beforePk: nil,
            scannedMessageCount: 500,
            lastStatusMessage: nil,
            consecutiveQuotaHits: 0
        )

        XCTAssertFalse(YearScanState.shouldApplyResumeState(current: current, incoming: stale))
        XCTAssertFalse(YearScanState.shouldApplyResumeState(current: current, incoming: stale))
    }

    func testResumeStateGuardAcceptsNewerPage() {
        let current = YearScanResumeState(
            accountIndex: 0,
            monthIndex: 12,
            totalMonths: 12,
            phase: .scanning,
            beforeDate: nil,
            beforePk: nil,
            scannedMessageCount: 2000,
            lastStatusMessage: nil,
            consecutiveQuotaHits: 0,
            currentPage: 5
        )
        let newer = YearScanResumeState(
            accountIndex: 0,
            monthIndex: 12,
            totalMonths: 12,
            phase: .scanning,
            beforeDate: nil,
            beforePk: nil,
            scannedMessageCount: 2500,
            lastStatusMessage: nil,
            consecutiveQuotaHits: 0,
            currentPage: 8
        )

        XCTAssertTrue(YearScanState.shouldApplyResumeState(current: current, incoming: newer))
        XCTAssertTrue(YearScanState.shouldApplyResumeState(current: current, incoming: newer))
    }

    func testThermalSeriousWithinCooldownReducesBatchNoPause() {
        var state = YearScanRunner.ThrottleState()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let seriousSnapshot = YearScanRunner.RuntimeSnapshot(
            thermalState: .serious,
            isLowPowerModeEnabled: false,
            memoryUsedBytes: 300_000_000
        )

        let first = YearScanRunner.makeThrottleDecision(
            snapshot: seriousSnapshot,
            now: t0,
            state: &state,
            intensity: .balanced
        )
        XCTAssertTrue(first.shouldPause)
        XCTAssertEqual(first.reason, .thermal)
        XCTAssertEqual(first.batchSize, 30)

        let second = YearScanRunner.makeThrottleDecision(
            snapshot: seriousSnapshot,
            now: t0.addingTimeInterval(5),
            state: &state,
            intensity: .balanced
        )
        XCTAssertFalse(second.shouldPause)
        XCTAssertEqual(second.reason, .thermal)
        XCTAssertEqual(second.batchSize, 50)
    }

    func testConsecutivePressureAccumulatesRecoveryPages() {
        var state = YearScanRunner.ThrottleState()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let hardMemory = YearScanRunner.RuntimeSnapshot(
            thermalState: .nominal,
            isLowPowerModeEnabled: false,
            memoryUsedBytes: 900_000_000
        )

        _ = YearScanRunner.makeThrottleDecision(
            snapshot: hardMemory,
            now: t0,
            state: &state,
            intensity: .balanced
        )
        XCTAssertTrue(state.recoveryPagesRemaining > 0)

        let nominal = YearScanRunner.RuntimeSnapshot(
            thermalState: .nominal,
            isLowPowerModeEnabled: false,
            memoryUsedBytes: 200_000_000
        )
        var recoveryDecisions = 0
        for i in 1...10 {
            let d = YearScanRunner.makeThrottleDecision(
                snapshot: nominal,
                now: t0.addingTimeInterval(Double(i) * 2),
                state: &state,
                intensity: .balanced
            )
            if d.reason == .recovery {
                recoveryDecisions += 1
            }
        }
        XCTAssertGreaterThan(recoveryDecisions, 0)
    }

    func testNormalizeResumeStateReturnsNilForZeroAccounts() {
        let raw = YearScanResumeState(
            accountIndex: 0,
            monthIndex: 3,
            totalMonths: 12,
            phase: .backfill,
            beforeDate: nil,
            beforePk: nil,
            scannedMessageCount: 100,
            lastStatusMessage: nil,
            consecutiveQuotaHits: 0
        )
        XCTAssertNil(YearScanRunner.normalizeResumeState(raw, accountsCount: 0, totalMonths: 12))
        XCTAssertNil(YearScanRunner.normalizeResumeState(raw, accountsCount: 1, totalMonths: 0))
    }
}
