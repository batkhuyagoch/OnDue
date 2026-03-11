import Foundation
import GRDB

protocol YearScanRepositorying: Sendable {
    func markInProgress(
        scannedMessageCount: Int,
        coverageSummary: String,
        statusMessage: String?,
        resumeState: YearScanResumeState?,
        scanRangeMonths: Int,
        scanIntensity: String
    ) async throws
    func markPaused(
        scannedMessageCount: Int,
        coverageSummary: String,
        statusMessage: String?,
        resumeState: YearScanResumeState?,
        scanRangeMonths: Int,
        scanIntensity: String
    ) async throws
    func saveRun(
        items: [YearScanItem],
        scannedMessageCount: Int,
        lastChecked: Date?,
        coverageSummary: String,
        scanRangeMonths: Int,
        scanIntensity: String,
        excludedProviderMessageIds: Set<String>
    ) async throws
    func upsertPartial(
        items: [YearScanItem],
        scannedMessageCount: Int,
        coverageSummary: String,
        statusMessage: String?,
        resumeState: YearScanResumeState?,
        scanRangeMonths: Int,
        scanIntensity: String,
        excludedProviderMessageIds: Set<String>,
        runToken: String,
        sequence: Int
    ) async throws
    func fetchLatest() async throws -> YearScanSnapshot?
    func fetchLatestState() async throws -> YearScanStateSnapshot?
    func fetchResumeState() async throws -> YearScanResumeState?
    func clearResumeState() async throws
    func clearState() async throws
}

final class YearScanRepository: YearScanRepositorying, @unchecked Sendable {
    private let database: Database
    private let stateId = "latest"
    private let partialWriteGuard = YearScanPartialWriteGuard()

    init(database: Database) {
        self.database = database
    }

    func saveRun(
        items: [YearScanItem],
        scannedMessageCount: Int,
        lastChecked: Date?,
        coverageSummary: String,
        scanRangeMonths: Int,
        scanIntensity: String,
        excludedProviderMessageIds: Set<String> = []
    ) async throws {
        try await database.writeAsync { db in
            _ = try YearScanResultRecord.deleteAll(db)
            let filteredItems = items.filter { !excludedProviderMessageIds.contains($0.providerMessageId) }
            let records = filteredItems.map(YearScanResultRecord.init(item:))
            for var record in records {
                try record.save(db)
            }
            try Self.pruneSuppressedRows(db: db)
            try Self.deleteRows(matchingProviderMessageIds: excludedProviderMessageIds, db: db)
            try Self.pruneUserHandledRows(db: db)

            var state = YearScanStateRecord(
                id: self.stateId,
                lastChecked: lastChecked,
                lastPaused: nil,
                scannedMessageCount: scannedMessageCount,
                coverageSummary: coverageSummary,
                isInProgress: false,
                statusMessage: nil,
                updatedAt: Date(),
                resumeStateJSON: nil,
                scanRangeMonths: scanRangeMonths,
                scanIntensity: scanIntensity
            )
            try state.save(db)
        }
    }

    func upsertPartial(
        items: [YearScanItem],
        scannedMessageCount: Int,
        coverageSummary: String,
        statusMessage: String?,
        resumeState: YearScanResumeState?,
        scanRangeMonths: Int,
        scanIntensity: String,
        excludedProviderMessageIds: Set<String>,
        runToken: String,
        sequence: Int
    ) async throws {
        guard sequence > 0 else { return }
        let shouldApply = await partialWriteGuard.shouldApply(runToken: runToken, sequence: sequence)
        guard shouldApply else { return }

        try await database.writeAsync { db in
            let filteredItems = items.filter { !excludedProviderMessageIds.contains($0.providerMessageId) }
            for item in filteredItems {
                var record = YearScanResultRecord(item: item)
                try record.save(db)
            }
            try Self.pruneSuppressedRows(db: db)
            try Self.deleteRows(matchingProviderMessageIds: excludedProviderMessageIds, db: db)
            try Self.pruneUserHandledRows(db: db)

            let existing = try YearScanStateRecord.fetchOne(db, key: self.stateId)
            var state = YearScanStateRecord(
                id: self.stateId,
                lastChecked: existing?.lastChecked,
                lastPaused: nil,
                scannedMessageCount: scannedMessageCount,
                coverageSummary: coverageSummary,
                isInProgress: true,
                statusMessage: statusMessage,
                updatedAt: Date(),
                resumeStateJSON: Self.encodeResumeState(resumeState),
                scanRangeMonths: scanRangeMonths,
                scanIntensity: scanIntensity
            )
            try state.save(db)
        }
    }

    func fetchLatest() async throws -> YearScanSnapshot? {
        try await database.readAsync { db in
            guard let state = try YearScanStateRecord.fetchOne(db, key: self.stateId) else { return nil }
            let allRecords = try YearScanResultRecord
                .order(Column("score").desc)
                .fetchAll(db)
            let promotedItems = allRecords
                .filter { $0.promotionDecision == LongScanPromotionDecision.promoted.rawValue }
                .map { $0.toItem() }
            let expectedEventSignals = allRecords
                .filter { $0.promotionDecision == LongScanPromotionDecision.expectedEvent.rawValue }
                .map { $0.toExpectedEventPatternSignal() }
            let droppedReasonCounts = allRecords.reduce(into: [LongScanPromotionReasonCode: Int]()) { counts, record in
                guard record.promotionDecision == LongScanPromotionDecision.dropped.rawValue,
                      let reasonCode = LongScanPromotionReasonCode(rawValue: record.promotionReasonCode) else {
                    return
                }
                counts[reasonCode, default: 0] += 1
            }
            return YearScanSnapshot(
                items: promotedItems,
                expectedEventSignals: expectedEventSignals,
                droppedReasonCounts: droppedReasonCounts,
                lastChecked: state.lastChecked,
                lastPaused: state.lastPaused,
                scannedMessageCount: state.scannedMessageCount,
                coverageSummary: state.coverageSummary,
                isInProgress: state.isInProgress,
                statusMessage: state.statusMessage,
                updatedAt: state.updatedAt,
                resumeState: Self.decodeResumeState(from: state.resumeStateJSON),
                scanRangeMonths: state.scanRangeMonths,
                scanIntensity: state.scanIntensity
            )
        }
    }

    func fetchLatestState() async throws -> YearScanStateSnapshot? {
        try await database.readAsync { db in
            guard let state = try YearScanStateRecord.fetchOne(db, key: self.stateId) else { return nil }
            return YearScanStateSnapshot(
                lastChecked: state.lastChecked,
                lastPaused: state.lastPaused,
                scannedMessageCount: state.scannedMessageCount,
                coverageSummary: state.coverageSummary,
                isInProgress: state.isInProgress,
                statusMessage: state.statusMessage,
                updatedAt: state.updatedAt,
                resumeState: Self.decodeResumeState(from: state.resumeStateJSON),
                scanRangeMonths: state.scanRangeMonths,
                scanIntensity: state.scanIntensity
            )
        }
    }

    func markInProgress(
        scannedMessageCount: Int,
        coverageSummary: String,
        statusMessage: String?,
        resumeState: YearScanResumeState? = nil,
        scanRangeMonths: Int = SyncPolicyStore.defaultCoverageMonths,
        scanIntensity: String = CoverageScanIntensity.balanced.rawValue
    ) async throws {
        try await database.writeAsync { db in
            let existing = try YearScanStateRecord.fetchOne(db, key: self.stateId)
            var state = YearScanStateRecord(
                id: self.stateId,
                lastChecked: existing?.lastChecked,
                lastPaused: nil,
                scannedMessageCount: scannedMessageCount,
                coverageSummary: coverageSummary,
                isInProgress: true,
                statusMessage: statusMessage,
                updatedAt: Date(),
                resumeStateJSON: Self.encodeResumeState(resumeState),
                scanRangeMonths: scanRangeMonths,
                scanIntensity: scanIntensity
            )
            try state.save(db)
        }
    }

    func markPaused(
        scannedMessageCount: Int,
        coverageSummary: String,
        statusMessage: String?,
        resumeState: YearScanResumeState?,
        scanRangeMonths: Int = SyncPolicyStore.defaultCoverageMonths,
        scanIntensity: String = CoverageScanIntensity.balanced.rawValue
    ) async throws {
        try await database.writeAsync { db in
            let existing = try YearScanStateRecord.fetchOne(db, key: self.stateId)
            var state = YearScanStateRecord(
                id: self.stateId,
                lastChecked: existing?.lastChecked,
                lastPaused: Date(),
                scannedMessageCount: scannedMessageCount,
                coverageSummary: coverageSummary,
                isInProgress: true,
                statusMessage: statusMessage,
                updatedAt: Date(),
                resumeStateJSON: Self.encodeResumeState(resumeState),
                scanRangeMonths: scanRangeMonths,
                scanIntensity: scanIntensity
            )
            try state.save(db)
        }
    }

    func fetchResumeState() async throws -> YearScanResumeState? {
        try await database.readAsync { db in
            guard let state = try YearScanStateRecord.fetchOne(db, key: self.stateId) else {
                return nil
            }
            return Self.decodeResumeState(from: state.resumeStateJSON)
        }
    }

    func clearResumeState() async throws {
        try await database.writeAsync { db in
            guard var state = try YearScanStateRecord.fetchOne(db, key: self.stateId) else {
                return
            }
            state.resumeStateJSON = nil
            state.lastPaused = nil
            if state.isInProgress {
                state.isInProgress = false
            }
            if state.statusMessage?.lowercased().contains("paused") == true {
                state.statusMessage = nil
            }
            state.updatedAt = Date()
            try state.save(db)
        }
    }

    func clearState() async throws {
        try await database.writeAsync { db in
            _ = try YearScanResultRecord.deleteAll(db)
            _ = try YearScanStateRecord.deleteAll(db)
        }
    }

    private static func encodeResumeState(_ state: YearScanResumeState?) -> String? {
        guard let state else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeResumeState(from json: String?) -> YearScanResumeState? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(YearScanResumeState.self, from: data)
    }

    private static func deleteRows(
        matchingProviderMessageIds ids: Set<String>,
        db: GRDB.Database
    ) throws {
        guard !ids.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        try db.execute(
            sql: "DELETE FROM year_scan_result WHERE providerMessageId IN (\(placeholders));",
            arguments: StatementArguments(Array(ids))
        )
    }

    private static func pruneSuppressedRows(db: GRDB.Database) throws {
        try db.execute(sql: """
            DELETE FROM year_scan_result
            WHERE messagePk IN (
                SELECT y.messagePk
                FROM year_scan_result y
                JOIN message m ON m.pk = y.messagePk
                JOIN suppression s ON s.isEnabled = 1
                    AND (s.mailboxAccountId = y.mailboxAccountId OR s.mailboxAccountId IS NULL)
                    AND (
                        (s.type = 'sender' AND lower(m.fromEmail) = s.value)
                        OR (s.type = 'domain' AND lower(m.fromDomain) = s.value)
                    )
            );
        """)
    }

    private static func pruneUserHandledRows(db: GRDB.Database) throws {
        try db.execute(sql: """
            DELETE FROM year_scan_result
            WHERE messagePk IN (
                SELECT y.messagePk
                FROM year_scan_result y
                JOIN obligation o ON o.messagePk = y.messagePk
                WHERE o.status IN ('dismissed', 'done', 'snoozed')
            );
        """)
    }
}

private actor YearScanPartialWriteGuard {
    private var activeRunToken: String?
    private var latestSequence: Int = 0

    func shouldApply(runToken: String, sequence: Int) -> Bool {
        if sequence == 1 || activeRunToken == nil {
            activeRunToken = runToken
            latestSequence = 0
        }
        guard activeRunToken == runToken else { return false }
        guard sequence > latestSequence else { return false }
        latestSequence = sequence
        return true
    }
}
