import Foundation
import GRDB

protocol FeedbackRepositorying: Sendable {
    func save(_ record: FeedbackRecord) async throws
}

protocol HypothesisReviewCalibrationRepositorying: Sendable {
    func fetchSnapshot(mailboxAccountId: String) async throws -> HypothesisReviewCalibrationSnapshot
    func applyFeedback(_ record: FeedbackRecord) async throws
}

protocol HypothesisMetricsRepositorying: Sendable {
    func increment(
        mailboxAccountId: String,
        profile: RuleEvaluationProfile,
        hypothesisIds: [String],
        counter: String
    ) async throws
}

protocol UserExposureEventRepositorying: Sendable {
    func logFirstExposure(_ record: UserExposureEventRecord) async throws -> Bool
    func fetchFirstExposureTimestamp(mailboxAccountId: String, obligationId: String) async throws -> Date?
    func countExposures(mailboxAccountId: String, hypothesisClass: String) async throws -> Int
}

protocol PolicyDiffArtifactRepositorying: Sendable {
    func save(_ record: PolicyDiffArtifactRecord) async throws
}

final class FeedbackRepository: FeedbackRepositorying, @unchecked Sendable {
    private let database: Database
    private let hypothesisReviewCalibrationRepository: HypothesisReviewCalibrationRepositorying
    private let userExposureEventRepository: UserExposureEventRepositorying

    init(
        database: Database,
        hypothesisReviewCalibrationRepository: HypothesisReviewCalibrationRepositorying,
        userExposureEventRepository: UserExposureEventRepositorying
    ) {
        self.database = database
        self.hypothesisReviewCalibrationRepository = hypothesisReviewCalibrationRepository
        self.userExposureEventRepository = userExposureEventRepository
    }

    func save(_ record: FeedbackRecord) async throws {
        try await database.writeAsync { db in
            try record.save(db)
        }
        try await hypothesisReviewCalibrationRepository.applyFeedback(record)
    }
}

final class HypothesisReviewCalibrationRepository: HypothesisReviewCalibrationRepositorying, @unchecked Sendable {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    func fetchSnapshot(mailboxAccountId: String) async throws -> HypothesisReviewCalibrationSnapshot {
        try await database.readAsync { db in
            let records = try HypothesisReviewCalibrationRecord
                .filter(Column("mailboxAccountId") == mailboxAccountId)
                .fetchAll(db)
            let map = Dictionary(uniqueKeysWithValues: records.map { record in
                let key = [
                    record.hypothesisId,
                    record.senderDomainClass,
                    record.labelCluster,
                    record.threadPattern
                ].joined(separator: "|")
                return (key, self.needsReviewConfidence(for: record))
            })
            return HypothesisReviewCalibrationSnapshot(needsReviewConfidenceByKey: map)
        }
    }

    func applyFeedback(_ record: FeedbackRecord) async throws {
        guard let hypothesisId = record.primaryHypothesisId, !hypothesisId.isEmpty else { return }
        let senderDomainClass = record.senderDomainClass ?? "all"
        let labelCluster = record.labelCluster ?? "all"
        let threadPattern = record.threadPattern ?? "all"

        try await database.writeAsync { db in
            let existing = try HypothesisReviewCalibrationRecord
                .filter(Column("mailboxAccountId") == record.mailboxAccountId)
                .filter(Column("hypothesisId") == hypothesisId)
                .filter(Column("senderDomainClass") == senderDomainClass)
                .filter(Column("labelCluster") == labelCluster)
                .filter(Column("threadPattern") == threadPattern)
                .fetchOne(db)

            var item = existing ?? HypothesisReviewCalibrationRecord(
                mailboxAccountId: record.mailboxAccountId,
                hypothesisId: hypothesisId,
                senderDomainClass: senderDomainClass,
                labelCluster: labelCluster,
                threadPattern: threadPattern
            )

            switch record.action {
            case .accepted:
                item.acceptedCount += 1
            case .dismissed:
                item.dismissedCount += 1
            case .snoozed:
                item.snoozedCount += 1
            default:
                break
            }
            item.updatedAt = Date()
            try item.save(db)
        }
        try await validateCounterConsistency(mailboxAccountId: record.mailboxAccountId, hypothesisId: hypothesisId)
    }

    private func needsReviewConfidence(for record: HypothesisReviewCalibrationRecord) -> Double {
        let total = record.acceptedCount + record.dismissedCount + record.snoozedCount
        guard total >= 3 else { return 0.55 }
        let positive = record.acceptedCount + record.snoozedCount
        let signedRatio = Double(positive - record.dismissedCount) / Double(max(total, 1))
        let adjusted = 0.55 + (signedRatio * 0.08)
        return min(max(adjusted, 0.45), 0.62)
    }

    private func validateCounterConsistency(mailboxAccountId: String, hypothesisId: String) async throws {
        let totalExposed = try await database.readAsync { db in
            try UserExposureEventRecord
                .filter(Column("mailboxAccountId") == mailboxAccountId)
                .filter(Column("hypothesisClass") == hypothesisId)
                .fetchCount(db)
        }
        let totals = try await database.readAsync { db in
            let accepted = try HypothesisReviewCalibrationRecord
                .filter(Column("mailboxAccountId") == mailboxAccountId)
                .filter(Column("hypothesisId") == hypothesisId)
                .fetchAll(db)
                .reduce(0) { $0 + $1.acceptedCount }
            let dismissed = try HypothesisReviewCalibrationRecord
                .filter(Column("mailboxAccountId") == mailboxAccountId)
                .filter(Column("hypothesisId") == hypothesisId)
                .fetchAll(db)
                .reduce(0) { $0 + $1.dismissedCount }
            let snoozed = try HypothesisReviewCalibrationRecord
                .filter(Column("mailboxAccountId") == mailboxAccountId)
                .filter(Column("hypothesisId") == hypothesisId)
                .fetchAll(db)
                .reduce(0) { $0 + $1.snoozedCount }
            return (accepted, dismissed, snoozed)
        }
        let actionTotal = totals.0 + totals.1 + totals.2
        if totalExposed < actionTotal {
            Logger.info(
                "metric_error.counter_consistency mailbox=\(mailboxAccountId) hypothesis=\(hypothesisId) totalExposed=\(totalExposed) actionTotal=\(actionTotal)"
            )
        }
    }
}

final class HypothesisMetricsRepository: HypothesisMetricsRepositorying, @unchecked Sendable {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    func increment(
        mailboxAccountId: String,
        profile: RuleEvaluationProfile,
        hypothesisIds: [String],
        counter: String
    ) async throws {
        guard !hypothesisIds.isEmpty else { return }
        let groupedCounts = Dictionary(grouping: hypothesisIds, by: { $0 })
            .mapValues(\.count)
        guard !groupedCounts.isEmpty else { return }
        try await database.writeAsync { db in
            let now = Date()
            let sortedEntries = groupedCounts.sorted { $0.key < $1.key }
            let valuePlaceholders = Array(repeating: "(?, ?, ?, ?, ?, ?, ?)", count: sortedEntries.count)
                .joined(separator: ", ")
            var arguments: [DatabaseValueConvertible] = []
            arguments.reserveCapacity(sortedEntries.count * 7)

            for (hypothesisId, delta) in sortedEntries {
                arguments.append(UUID().uuidString)
                arguments.append(mailboxAccountId)
                arguments.append(profile.rawValue)
                arguments.append(hypothesisId)
                arguments.append(counter)
                arguments.append(delta)
                arguments.append(now)
            }

            try db.execute(
                sql: """
                    INSERT INTO \(HypothesisMetricCounterRecord.databaseTableName)
                    (id, mailboxAccountId, profile, hypothesisId, counter, count, updatedAt)
                    VALUES \(valuePlaceholders)
                    ON CONFLICT(mailboxAccountId, profile, hypothesisId, counter)
                    DO UPDATE SET
                        count = count + excluded.count,
                        updatedAt = excluded.updatedAt
                """,
                arguments: StatementArguments(arguments)
            )
        }
    }
}

final class UserExposureEventRepository: UserExposureEventRepositorying, @unchecked Sendable {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    func logFirstExposure(_ record: UserExposureEventRecord) async throws -> Bool {
        try await database.writeAsync { db in
            // Exposure logging is best-effort telemetry. Skip insert if parent rows
            // are not durable yet (e.g., mock/debug flows) to avoid FK hard-fail.
            let mailboxExists = try MailboxAccountRecord
                .filter(Column("id") == record.mailboxAccountId)
                .fetchCount(db) > 0
            guard mailboxExists else { return false }

            let obligationExists = try ObligationRecord
                .filter(Column("id") == record.obligationId)
                .fetchCount(db) > 0
            guard obligationExists else { return false }

            let existing = try UserExposureEventRecord
                .filter(Column("mailboxAccountId") == record.mailboxAccountId)
                .filter(Column("obligationId") == record.obligationId)
                .filter(Column("digestRenderId") == record.digestRenderId)
                .fetchCount(db)
            guard existing == 0 else { return false }
            do {
                try record.insert(db)
            } catch let dbError as DatabaseError where dbError.extendedResultCode == .SQLITE_CONSTRAINT_FOREIGNKEY {
                return false
            }
            return true
        }
    }

    func fetchFirstExposureTimestamp(mailboxAccountId: String, obligationId: String) async throws -> Date? {
        try await database.readAsync { db in
            try UserExposureEventRecord
                .filter(Column("mailboxAccountId") == mailboxAccountId)
                .filter(Column("obligationId") == obligationId)
                .order(Column("exposedAt").asc)
                .fetchOne(db)?
                .exposedAt
        }
    }

    func countExposures(mailboxAccountId: String, hypothesisClass: String) async throws -> Int {
        try await database.readAsync { db in
            try UserExposureEventRecord
                .filter(Column("mailboxAccountId") == mailboxAccountId)
                .filter(Column("hypothesisClass") == hypothesisClass)
                .fetchCount(db)
        }
    }
}

final class PolicyDiffArtifactRepository: PolicyDiffArtifactRepositorying, @unchecked Sendable {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    func save(_ record: PolicyDiffArtifactRecord) async throws {
        try await database.writeAsync { db in
            try record.save(db)
        }
    }
}
