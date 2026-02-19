import Foundation
import GRDB

protocol YearScanRepositorying: Sendable {
    func markInProgress(
        scannedMessageCount: Int,
        coverageSummary: String,
        statusMessage: String?
    ) async throws
    func saveRun(
        items: [YearScanItem],
        scannedMessageCount: Int,
        lastChecked: Date?,
        coverageSummary: String
    ) async throws
    func fetchLatest() async throws -> YearScanSnapshot?
    func clearState() async throws
}

final class YearScanRepository: YearScanRepositorying, @unchecked Sendable {
    private let database: Database
    private let stateId = "latest"

    init(database: Database) {
        self.database = database
    }

    func saveRun(
        items: [YearScanItem],
        scannedMessageCount: Int,
        lastChecked: Date?,
        coverageSummary: String
    ) async throws {
        try await database.writeAsync { db in
            _ = try YearScanResultRecord.deleteAll(db)
            let records = items.map(YearScanResultRecord.init(item:))
            for var record in records {
                try record.insert(db)
            }

            var state = YearScanStateRecord(
                id: self.stateId,
                lastChecked: lastChecked,
                scannedMessageCount: scannedMessageCount,
                coverageSummary: coverageSummary,
                isInProgress: false,
                statusMessage: nil,
                updatedAt: Date()
            )
            try state.save(db)
        }
    }

    func fetchLatest() async throws -> YearScanSnapshot? {
        try await database.readAsync { db in
            guard let state = try YearScanStateRecord.fetchOne(db, key: self.stateId) else { return nil }
            let items = try YearScanResultRecord
                .order(Column("score").desc)
                .fetchAll(db)
                .map { $0.toItem() }
            return YearScanSnapshot(
                items: items,
                lastChecked: state.lastChecked,
                scannedMessageCount: state.scannedMessageCount,
                coverageSummary: state.coverageSummary,
                isInProgress: state.isInProgress,
                statusMessage: state.statusMessage,
                updatedAt: state.updatedAt
            )
        }
    }

    func markInProgress(
        scannedMessageCount: Int,
        coverageSummary: String,
        statusMessage: String?
    ) async throws {
        try await database.writeAsync { db in
            let existing = try YearScanStateRecord.fetchOne(db, key: self.stateId)
            var state = YearScanStateRecord(
                id: self.stateId,
                lastChecked: existing?.lastChecked,
                scannedMessageCount: scannedMessageCount,
                coverageSummary: coverageSummary,
                isInProgress: true,
                statusMessage: statusMessage,
                updatedAt: Date()
            )
            try state.save(db)
        }
    }

    func clearState() async throws {
        try await database.writeAsync { db in
            _ = try YearScanResultRecord.deleteAll(db)
            _ = try YearScanStateRecord.deleteAll(db)
        }
    }
}
