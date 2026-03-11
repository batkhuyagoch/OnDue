import XCTest
@testable import OnDue

final class YearScanRepositoryTests: XCTestCase {
    private var database: OnDue.Database!
    private var repository: YearScanRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: true)
        repository = YearScanRepository(database: database)
    }

    func testMarkPausedPersistsResumeState() async throws {
        let resume = YearScanResumeState(
            accountIndex: 0,
            monthIndex: 5,
            totalMonths: 12,
            phase: .backfill,
            beforeDate: nil,
            beforePk: nil,
            scannedMessageCount: 420,
            lastStatusMessage: "Backfilling month 6/12",
            consecutiveQuotaHits: 1
        )

        try await repository.markPaused(
            scannedMessageCount: 420,
            coverageSummary: YearScanRunner.coverageSummary,
            statusMessage: "Paused due to quota",
            resumeState: resume
        )

        let snapshot = try await repository.fetchLatest()
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.isInProgress, true)
        XCTAssertEqual(snapshot?.statusMessage, "Paused due to quota")
        XCTAssertEqual(snapshot?.resumeState?.monthIndex, 5)
        XCTAssertNotNil(snapshot?.lastPaused)
        XCTAssertEqual(snapshot?.scanRangeMonths, SyncPolicyStore.defaultCoverageMonths)
        XCTAssertEqual(snapshot?.scanIntensity, CoverageScanIntensity.balanced.rawValue)
    }

    func testClearResumeStateClearsCheckpoint() async throws {
        let resume = YearScanResumeState(
            accountIndex: 0,
            monthIndex: 2,
            totalMonths: 12,
            phase: .backfill,
            beforeDate: nil,
            beforePk: nil,
            scannedMessageCount: 120,
            lastStatusMessage: "Backfilling month 3/12",
            consecutiveQuotaHits: 0
        )

        try await repository.markInProgress(
            scannedMessageCount: 120,
            coverageSummary: YearScanRunner.coverageSummary,
            statusMessage: "In progress",
            resumeState: resume
        )
        try await repository.clearResumeState()

        let fetchedResume = try await repository.fetchResumeState()
        XCTAssertNil(fetchedResume)

        let snapshot = try await repository.fetchLatest()
        XCTAssertEqual(snapshot?.isInProgress, false)
    }

    func testMarkInProgressPersistsThrottleMetadataInResumeState() async throws {
        let resume = YearScanResumeState(
            accountIndex: 0,
            monthIndex: 9,
            totalMonths: 12,
            phase: .scanning,
            beforeDate: Date(timeIntervalSince1970: 1_700_100_000),
            beforePk: 42,
            scannedMessageCount: 900,
            lastStatusMessage: "Scanning inbox... 900 messages",
            consecutiveQuotaHits: 0,
            lastThrottleReason: "memory",
            lastKnownMemoryBytes: 680_000_000,
            lastKnownThermalState: "fair",
            lastKnownBatchSize: 75
        )

        try await repository.markInProgress(
            scannedMessageCount: 900,
            coverageSummary: YearScanRunner.coverageSummary,
            statusMessage: "Optimizing for device memory...",
            resumeState: resume,
            scanRangeMonths: 24,
            scanIntensity: CoverageScanIntensity.faster.rawValue
        )

        let fetched = try await repository.fetchResumeState()
        XCTAssertEqual(fetched?.lastThrottleReason, "memory")
        XCTAssertEqual(fetched?.lastKnownMemoryBytes, 680_000_000)
        XCTAssertEqual(fetched?.lastKnownThermalState, "fair")
        XCTAssertEqual(fetched?.lastKnownBatchSize, 75)
        XCTAssertEqual(fetched?.configuredRangeMonths, nil)

        let snapshot = try await repository.fetchLatest()
        XCTAssertEqual(snapshot?.scanRangeMonths, 24)
        XCTAssertEqual(snapshot?.scanIntensity, CoverageScanIntensity.faster.rawValue)
    }

    func testFetchLatestPartitionsPromotionOutcomes() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let promoted = YearScanItem(
            mailboxAccountId: "acct",
            messagePk: 101,
            providerMessageId: "m-promoted",
            threadId: "thread-promoted",
            subject: "Invoice due",
            snippet: "Please pay by Friday",
            score: 0.91,
            matchedReasons: ["payment overdue"],
            source: .scan,
            promotionDecision: .promoted,
            promotionReasonCode: .promotedActionable,
            confidence: 0.91,
            dueDate: now
        )
        let expectedEvent = YearScanItem(
            mailboxAccountId: "acct",
            messagePk: 102,
            providerMessageId: "m-expected",
            threadId: "thread-expected",
            subject: "Monthly statement available",
            snippet: "Your statement is ready",
            score: 0.84,
            matchedReasons: ["regular monthly statement"],
            source: .scan,
            promotionDecision: .expectedEvent,
            promotionReasonCode: .convertedExpectedEvent,
            confidence: 0.84,
            dueDate: nil
        )
        let droppedSuppressed = YearScanItem(
            mailboxAccountId: "acct",
            messagePk: 103,
            providerMessageId: "m-drop-1",
            threadId: "thread-drop-1",
            subject: "Blocked sender",
            snippet: "Suppressed content",
            score: 0.75,
            matchedReasons: ["blocked sender"],
            source: .scan,
            promotionDecision: .dropped,
            promotionReasonCode: .suppressed,
            confidence: 0.75,
            dueDate: nil
        )
        let droppedLowConfidence = YearScanItem(
            mailboxAccountId: "acct",
            messagePk: 104,
            providerMessageId: "m-drop-2",
            threadId: "thread-drop-2",
            subject: "Weak evidence",
            snippet: "Maybe actionable",
            score: 0.41,
            matchedReasons: ["low confidence"],
            source: .scan,
            promotionDecision: .dropped,
            promotionReasonCode: .lowConfidence,
            confidence: 0.41,
            dueDate: nil
        )

        try await repository.saveRun(
            items: [promoted, expectedEvent, droppedSuppressed, droppedLowConfidence],
            scannedMessageCount: 200,
            lastChecked: now,
            coverageSummary: YearScanRunner.coverageSummary,
            scanRangeMonths: 12,
            scanIntensity: CoverageScanIntensity.balanced.rawValue
        )

        let snapshot = try await repository.fetchLatest()
        XCTAssertEqual(snapshot?.items.count, 1)
        XCTAssertEqual(snapshot?.items.first?.providerMessageId, "m-promoted")
        XCTAssertEqual(snapshot?.expectedEventSignals.count, 1)
        XCTAssertEqual(snapshot?.expectedEventSignals.first?.providerMessageId, "m-expected")
        XCTAssertEqual(snapshot?.droppedReasonCounts[.suppressed], 1)
        XCTAssertEqual(snapshot?.droppedReasonCounts[.lowConfidence], 1)
    }

    func testUpsertPartialFiltersExcludedAndPreventsResurrection() async throws {
        let item = YearScanItem(
            mailboxAccountId: "acct",
            messagePk: 201,
            providerMessageId: "msg-201",
            threadId: "thread-201",
            subject: "Action needed",
            snippet: "Please complete this",
            score: 0.92,
            matchedReasons: ["action required"],
            source: .scan,
            promotionDecision: .promoted,
            promotionReasonCode: .promotedActionable,
            confidence: 0.92,
            dueDate: Date()
        )

        try await repository.upsertPartial(
            items: [item],
            scannedMessageCount: 10,
            coverageSummary: YearScanRunner.coverageSummary,
            statusMessage: "Scanning inbox... 10 messages",
            resumeState: nil,
            scanRangeMonths: 12,
            scanIntensity: CoverageScanIntensity.balanced.rawValue,
            excludedProviderMessageIds: [],
            runToken: "run-1",
            sequence: 1
        )

        var snapshot = try await repository.fetchLatest()
        XCTAssertEqual(snapshot?.items.count, 1)

        try await repository.upsertPartial(
            items: [item],
            scannedMessageCount: 20,
            coverageSummary: YearScanRunner.coverageSummary,
            statusMessage: "Scanning inbox... 20 messages",
            resumeState: nil,
            scanRangeMonths: 12,
            scanIntensity: CoverageScanIntensity.balanced.rawValue,
            excludedProviderMessageIds: ["msg-201"],
            runToken: "run-1",
            sequence: 2
        )

        snapshot = try await repository.fetchLatest()
        XCTAssertEqual(snapshot?.items.count, 0)

        try await repository.upsertPartial(
            items: [item],
            scannedMessageCount: 30,
            coverageSummary: YearScanRunner.coverageSummary,
            statusMessage: "Scanning inbox... 30 messages",
            resumeState: nil,
            scanRangeMonths: 12,
            scanIntensity: CoverageScanIntensity.balanced.rawValue,
            excludedProviderMessageIds: ["msg-201"],
            runToken: "run-1",
            sequence: 3
        )

        snapshot = try await repository.fetchLatest()
        XCTAssertEqual(snapshot?.items.count, 0)
    }

    func testUpsertPartialRejectsOutOfOrderSequences() async throws {
        let first = YearScanItem(
            mailboxAccountId: "acct",
            messagePk: 301,
            providerMessageId: "msg-301",
            threadId: "thread-301",
            subject: "First",
            snippet: "First",
            score: 0.80,
            matchedReasons: ["first"],
            source: .scan,
            promotionDecision: .promoted,
            promotionReasonCode: .promotedActionable,
            confidence: 0.80,
            dueDate: Date()
        )
        let second = YearScanItem(
            mailboxAccountId: "acct",
            messagePk: 302,
            providerMessageId: "msg-302",
            threadId: "thread-302",
            subject: "Second",
            snippet: "Second",
            score: 0.81,
            matchedReasons: ["second"],
            source: .scan,
            promotionDecision: .promoted,
            promotionReasonCode: .promotedActionable,
            confidence: 0.81,
            dueDate: Date()
        )
        let stale = YearScanItem(
            mailboxAccountId: "acct",
            messagePk: 303,
            providerMessageId: "msg-303",
            threadId: "thread-303",
            subject: "Stale",
            snippet: "Stale",
            score: 0.99,
            matchedReasons: ["stale"],
            source: .scan,
            promotionDecision: .promoted,
            promotionReasonCode: .promotedActionable,
            confidence: 0.99,
            dueDate: Date()
        )

        try await repository.upsertPartial(
            items: [first],
            scannedMessageCount: 10,
            coverageSummary: YearScanRunner.coverageSummary,
            statusMessage: "Scanning inbox... 10 messages",
            resumeState: nil,
            scanRangeMonths: 12,
            scanIntensity: CoverageScanIntensity.balanced.rawValue,
            excludedProviderMessageIds: [],
            runToken: "run-2",
            sequence: 1
        )

        try await repository.upsertPartial(
            items: [second],
            scannedMessageCount: 20,
            coverageSummary: YearScanRunner.coverageSummary,
            statusMessage: "Scanning inbox... 20 messages",
            resumeState: nil,
            scanRangeMonths: 12,
            scanIntensity: CoverageScanIntensity.balanced.rawValue,
            excludedProviderMessageIds: [],
            runToken: "run-2",
            sequence: 3
        )

        try await repository.upsertPartial(
            items: [stale],
            scannedMessageCount: 15,
            coverageSummary: YearScanRunner.coverageSummary,
            statusMessage: "Scanning inbox... 15 messages",
            resumeState: nil,
            scanRangeMonths: 12,
            scanIntensity: CoverageScanIntensity.balanced.rawValue,
            excludedProviderMessageIds: [],
            runToken: "run-2",
            sequence: 2
        )

        let snapshot = try await repository.fetchLatest()
        let ids = Set(snapshot?.items.map(\.providerMessageId) ?? [])
        XCTAssertTrue(ids.contains("msg-301"))
        XCTAssertTrue(ids.contains("msg-302"))
        XCTAssertFalse(ids.contains("msg-303"))
    }

    func testMarkPausedPersistsMonthSummariesAndResumePoint() async throws {
        let summaries = [
            YearScanMonthSummary(
                monthLabel: "Jan 2025",
                monthIndex: 0,
                messagesScanned: 420,
                promotedCount: 4,
                expectedCount: 2,
                droppedCount: 3,
                isInProgress: false,
                completedAt: Date(timeIntervalSince1970: 1_701_000_000)
            ),
            YearScanMonthSummary(
                monthLabel: "Feb 2025",
                monthIndex: 1,
                messagesScanned: 200,
                promotedCount: 2,
                expectedCount: 1,
                droppedCount: 1,
                isInProgress: true,
                completedAt: nil
            )
        ]
        let resume = YearScanResumeState(
            accountIndex: 0,
            monthIndex: 1,
            totalMonths: 12,
            phase: .scanning,
            beforeDate: Date(timeIntervalSince1970: 1_701_100_000),
            beforePk: 144,
            scannedMessageCount: 620,
            lastStatusMessage: "Scanning inbox... 620 messages",
            consecutiveQuotaHits: 0,
            currentMonthLabel: "Feb 2025",
            currentPage: 8,
            monthSummaries: summaries
        )

        try await repository.markPaused(
            scannedMessageCount: 620,
            coverageSummary: YearScanRunner.coverageSummary,
            statusMessage: "Paused while scanning",
            resumeState: resume
        )

        let snapshot = try await repository.fetchLatest()
        XCTAssertEqual(snapshot?.resumeState?.currentMonthLabel, "Feb 2025")
        XCTAssertEqual(snapshot?.resumeState?.currentPage, 8)
        XCTAssertEqual(snapshot?.resumeState?.monthSummaries?.count, 2)
        XCTAssertEqual(snapshot?.resumeState?.monthSummaries?.first?.monthLabel, "Jan 2025")
    }
}

